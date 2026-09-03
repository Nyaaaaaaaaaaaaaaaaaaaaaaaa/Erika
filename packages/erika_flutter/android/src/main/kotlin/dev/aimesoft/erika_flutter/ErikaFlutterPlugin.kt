package dev.aimesoft.erika_flutter

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import android.view.Choreographer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.FlutterLifecycleAdapter
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.EOFException
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

private class AndroidImageDecodeJob(
    val dartOperationId: Long,
    val nativeOperationId: Long,
    val engineGeneration: Long,
    val result: MethodChannel.Result,
) {
    val cancelled = AtomicBoolean(false)
    val completed = AtomicBoolean(false)
    val started = AtomicBoolean(false)
    val ownsHdrReservation = AtomicBoolean(false)

    @Volatile
    var future: Future<*>? = null
}

private class AndroidImageDecodeException(
    val kind: Int,
    message: String,
) : IllegalStateException(message)

private data class AndroidImagePolicy(
    val maxEncodedBytes: Long,
    val maxSourcePixels: Long,
    val maxOutputPixels: Long,
    val maxPacketsBeforeFrame: Int,
    val decodeTimeoutMillis: Long,
    val maxQueuedDecodes: Int,
    val maxConcurrentDecodes: Int,
)

internal class AndroidSdrImageTexture(
    val plugin: ErikaFlutterPlugin,
    val producer: TextureRegistry.SurfaceProducer,
    val handle: Long,
    val width: Int,
    val height: Int,
    val engineGeneration: Long,
) : TextureRegistry.SurfaceProducer.Callback {
    val disposed = AtomicBoolean(false)
    val surfaceAttached = AtomicBoolean(false)

    val textureId: Long
        get() = producer.id()

    override fun onSurfaceAvailable() {
        plugin.renderSdrImageTexture(this)
    }

    override fun onSurfaceCleanup() {
        plugin.detachSdrImageTextureSurface(this)
    }
}

private fun boundedImageExtent(
    sourceWidth: Int,
    sourceHeight: Int,
    requestedWidth: Int,
    requestedHeight: Int,
): Pair<Int, Int> {
    require(sourceWidth > 0 && sourceHeight > 0) { "invalid source image dimensions" }
    val maxWidth = if (requestedWidth > 0) requestedWidth else sourceWidth
    val maxHeight = if (requestedHeight > 0) requestedHeight else sourceHeight
    if (sourceWidth <= maxWidth && sourceHeight <= maxHeight) {
        return sourceWidth to sourceHeight
    }
    return if (maxWidth.toLong() * sourceHeight <= maxHeight.toLong() * sourceWidth) {
        maxWidth to maxOf(1, sourceHeight.toLong().times(maxWidth).div(sourceWidth).toInt())
    } else {
        maxOf(1, sourceWidth.toLong().times(maxHeight).div(sourceHeight).toInt()) to maxHeight
    }
}

class ErikaFlutterPlugin :
    FlutterPlugin,
    ActivityAware,
    LifecycleEventObserver,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var choreographer: Choreographer
    private lateinit var audioFocus: ErikaAudioFocus
    private lateinit var mediaSession: ErikaMediaSession
    private lateinit var mainHandler: Handler
    private lateinit var presenterThread: AndroidPresenterThread
    private lateinit var contentPreparationExecutor: ExecutorService
    private lateinit var imageDecodeExecutor: ThreadPoolExecutor
    private lateinit var imageSurfaceExecutor: ExecutorService
    private lateinit var imageCleanupExecutor: ExecutorService
    private lateinit var textureRegistry: TextureRegistry
    private val presenterCreates = AndroidPresenterCreateRegistry<AndroidPresenterThread>()
    @Volatile
    private var engineAttachmentGeneration = 0L
    @Volatile
    private var contentSpoolScavengeFuture: Future<*>? = null
    private val players = linkedMapOf<Long, AndroidPlayerHost>()
    private val imageDecodeJobsByDartOperationId =
        ConcurrentHashMap<Long, AndroidImageDecodeJob>()
    private val hdrImageHandles = ConcurrentHashMap.newKeySet<Long>()
    private val sdrImageTextures = ConcurrentHashMap<Long, AndroidSdrImageTexture>()
    private val imageOwnershipLock = Any()
    private var hdrImageDecodeReserved = false
    @Volatile private var imageSubsystemClosing = false
    @Volatile private var imagePolicy = DEFAULT_IMAGE_POLICY
    private val hdrImageViewOwners = ConcurrentHashMap<Long, HdrImageViewOwner>()
    private val hdrImageViews = ConcurrentHashMap<Int, Long>()
    private val hdrImageSurfaceGenerations =
        ConcurrentHashMap<Int, HdrImageSurfaceGeneration>()
    private val hdrImagesDisposing = ConcurrentHashMap.newKeySet<Long>()
    private val imageDecodeCount = AtomicLong(0L)
    private val imageDecodeInflight = AtomicInteger(0)
    private val imageActiveHandles = AtomicInteger(0)
    private val imageQueuedCancelled = AtomicLong(0L)
    private val videoViews = linkedMapOf<Int, ErikaAndroidVideoView>()
    private var eventSink: EventChannel.EventSink? = null
    private var frameScheduled = false
    @Volatile
    private var attachedToEngine = false
    private var activityLifecycle: Lifecycle? = null
    private var activity: Activity? = null
    private var activityActive = false
    private var activeMediaPlayerId: Long? = null
    private val renderRequests = AndroidLatestTaskCoalescer<AndroidRenderRequest>()
    private val renderGeneration = AtomicLong(0L)
    private val renderThreadReported = AtomicBoolean(false)
    private val backgroundTickQueued = AtomicBoolean(false)
    private val eventPollQueued = AtomicBoolean(false)
    private val immediateEventPollLatch = AndroidImmediateEventPollLatch()
    private val pendingPlayResults = mutableMapOf<PendingPlayKey, MutableList<MethodChannel.Result>>()
    private var eventPollTimerScheduled = false
    private var eventPollIdleRounds = 0

    internal val isActivityActive: Boolean
        get() = attachedToEngine && activityActive
    private val frameCallback = Choreographer.FrameCallback { frameTimeNanos ->
        frameScheduled = false
        if (!isActivityActive) {
            return@FrameCallback
        }
        val renderTargets = players.values
            .filter(AndroidPlayerHost::shouldTick)
            .map { host ->
                AndroidRenderTarget(
                    host,
                    host.currentRenderRequestGeneration,
                )
            }
        if (renderTargets.isEmpty()) {
            return@FrameCallback
        }
        val timeSeconds = frameTimeNanos.toDouble() / 1_000_000_000.0
        enqueueRenderTick(renderTargets, timeSeconds)
        refreshFrameScheduling()
    }

    private val eventPollRunnable = object : Runnable {
        override fun run() {
            eventPollTimerScheduled = false
            scheduleEventPoll()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        choreographer = Choreographer.getInstance()
        mainHandler = Handler(Looper.getMainLooper())
        presenterThread = AndroidPresenterThread()
        engineAttachmentGeneration = presenterCreates.attach(presenterThread)
        renderThreadReported.set(false)
        backgroundTickQueued.set(false)
        eventPollQueued.set(false)
        immediateEventPollLatch.clear()
        contentPreparationExecutor = newContentPreparationExecutor()
        imageDecodeExecutor = newImageDecodeExecutor(imagePolicy)
        imageSubsystemClosing = false
        imageSurfaceExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "erika-image-surface").apply { isDaemon = true }
        }
        imageCleanupExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "erika-image-cleanup").apply { isDaemon = true }
        }
        contentSpoolScavengeFuture = scheduleContentSpoolStartupScavenge()
        audioFocus = ErikaAudioFocus(
            applicationContext,
            onFocusLoss = ::handleAudioFocusLoss,
            onFocusGain = ::handleAudioFocusGain,
        )
        mediaSession = ErikaMediaSession(
            applicationContext,
            object : ErikaMediaCommandHandler {
                override fun play(playerId: Long) = performSystemMediaCommand(playerId, "play")
                override fun pause(playerId: Long) = performSystemMediaCommand(playerId, "pause")
                override fun stop(playerId: Long) = performSystemMediaCommand(playerId, "stop")
                override fun seek(playerId: Long, positionMicros: Long) =
                    performSystemMediaCommand(playerId, "seek", mapOf("positionMicros" to positionMicros))
                override fun previous(playerId: Long) =
                    emitSystemMediaNavigation(playerId, SYSTEM_MEDIA_NAVIGATION_PREVIOUS)
                override fun next(playerId: Long) =
                    emitSystemMediaNavigation(playerId, SYSTEM_MEDIA_NAVIGATION_NEXT)
            },
        )
        ErikaMediaCommandReceiver.register(this, mediaSession::dispatch)
        ErikaMediaPlaybackService.registerTickHandler(this, ::performBackgroundPlaybackTick)
        methodChannel = MethodChannel(binding.binaryMessenger, PLAYER_CHANNEL)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory(
            VIDEO_VIEW_TYPE,
            ErikaAndroidVideoViewFactory(this),
        )
        binding.platformViewRegistry.registerViewFactory(
            HDR_VIDEO_VIEW_TYPE,
            ErikaAndroidVideoViewFactory(this, useHdrSurface = true),
        )
        binding.platformViewRegistry.registerViewFactory(
            HDR_IMAGE_VIEW_TYPE,
            ErikaAndroidHdrImageViewFactory(this, engineAttachmentGeneration),
        )
        attachedToEngine = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachFromActivity()
        attachedToEngine = false
        val retiringEngineGeneration = engineAttachmentGeneration
        val retiringImageDecodeExecutor = imageDecodeExecutor
        val retiringImageSurfaceExecutor = imageSurfaceExecutor
        val retiringImageCleanupExecutor = imageCleanupExecutor
        val closingImages = synchronized(imageOwnershipLock) {
            imageSubsystemClosing = true
            hdrImageDecodeReserved = false
            hdrImageHandles.toList() to sdrImageTextures.values.toList()
        }
        val retiringPresenterThread = presenterThread
        presenterCreates.detach(retiringPresenterThread).forEach { pending ->
            if (!retiringPresenterThread.post { ErikaNative.nativeDestroy(pending.handle) }) {
                Log.e(
                    TAG,
                    "Unable to retire pending presenter ${pending.handle} before engine detach",
                )
            }
        }
        cancelFrameCallback()
        mainHandler.removeCallbacks(eventPollRunnable)
        eventPollTimerScheduled = false
        eventPollIdleRounds = 0
        eventPollQueued.set(false)
        immediateEventPollLatch.clear()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        videoViews.values.toList().forEach(ErikaAndroidVideoView::dispose)
        videoViews.clear()
        players.values.toList().forEach(::destroyPlayer)
        players.clear()
        if (::presenterThread.isInitialized) {
            retiringPresenterThread.close()
        }
        if (::contentPreparationExecutor.isInitialized) {
            contentPreparationExecutor.shutdownNow()
        }
        imageDecodeJobsByDartOperationId.values.forEach { job ->
            job.cancelled.set(true)
            ErikaNative.nativeCancelImageDecode(job.nativeOperationId)
            job.future?.cancel(true)
        }
        imageDecodeJobsByDartOperationId.clear()
        if (::imageDecodeExecutor.isInitialized) {
            closingImages.first.forEach { imageId ->
                retiringImageSurfaceExecutor.execute {
                    ErikaNative.nativeDetachImageSurface(imageId)
                    retiringImageCleanupExecutor.execute {
                        val response = NativeJson.decodeResponse(ErikaNative.nativeDestroyImage(imageId))
                        if (response.ok && hdrImageHandles.remove(imageId)) {
                            imageActiveHandles.decrementAndGet()
                        } else if (!response.ok) {
                            Log.e(TAG, "Unable to destroy HDR image $imageId: ${response.error}")
                        }
                    }
                }
            }
            closingImages.second.forEach { texture ->
                if (!texture.disposed.compareAndSet(false, true)) return@forEach
                sdrImageTextures.remove(texture.textureId, texture)
                texture.producer.setCallback(null)
                retiringImageSurfaceExecutor.execute {
                    if (texture.surfaceAttached.compareAndSet(true, false)) {
                        ErikaNative.nativeDetachImageSurface(texture.handle)
                    }
                    val response = NativeJson.decodeResponse(
                        ErikaNative.nativeDestroyImage(texture.handle),
                    )
                    if (response.ok) imageActiveHandles.decrementAndGet()
                    else Log.e(
                        TAG,
                        "Unable to destroy SDR texture ${texture.textureId}: ${response.error}",
                    )
                    mainHandler.post(texture.producer::release)
                }
            }
            retiringImageSurfaceExecutor.execute { retiringImageCleanupExecutor.shutdown() }
            hdrImageViewOwners.entries.removeIf {
                it.value.engineGeneration == retiringEngineGeneration
            }
            hdrImageViews.entries.removeIf { it.value == retiringEngineGeneration }
            hdrImageSurfaceGenerations.entries.removeIf {
                it.value.engineGeneration == retiringEngineGeneration
            }
            retiringImageDecodeExecutor.shutdown()
        }
        if (::imageSurfaceExecutor.isInitialized) retiringImageSurfaceExecutor.shutdown()
        audioFocus.abandon()
        ErikaMediaCommandReceiver.unregister(this)
        ErikaMediaPlaybackService.unregisterTickHandler(this)
        mediaSession.release()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachFromActivity()
    }

    override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
        val lifecycle = activityLifecycle
        if (lifecycle == null || source.lifecycle !== lifecycle) {
            return
        }
        val active = androidActivityActiveForEvent(event) ?: return
        Log.i(
            TAG,
            "activityLifecycleEvent event=$event state=${lifecycle.currentState} active=$active",
        )
        setActivityActive(active)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        players.values.forEach(::drainEvents)
        refreshFrameScheduling()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configureImagePipeline" -> configureImagePipeline(arguments(call), result)
                "getImageCapabilities" -> getImageCapabilities(result)
                "decodeImage" -> decodeImage(arguments(call), result)
                "decodeSdrTexture" -> decodeSdrTexture(arguments(call), result)
                "decodeHdrImage" -> decodeHdrImage(arguments(call), result)
                "disposeSdrTexture" -> disposeSdrTexture(arguments(call), result)
                "disposeHdrImage" -> disposeHdrImage(arguments(call), result)
                "cancelImageDecode" -> cancelImageDecode(arguments(call), result)
                "getImageDiagnostics" -> getImageDiagnostics(result)
                "create" -> createPlayer(arguments(call), result)
                "dispose" -> disposePlayer(arguments(call), result)
                "attachView" -> attachView(arguments(call), result)
                "detachView" -> detachView(arguments(call), result)
                "attachOverlay" -> attachOverlay(arguments(call), result)
                "detachOverlay" -> detachOverlay(arguments(call), result)
                "setOverlayFrame" -> setOverlayFrame(arguments(call), result)
                "screenshot" -> captureFrame(arguments(call), result)
                "setMediaMetadata" -> setMediaMetadata(arguments(call), result)
                "setSystemMediaNavigation" -> setSystemMediaNavigation(arguments(call), result)
                "registerSubtitleMemoryFont" -> registerSubtitleMemoryFont(arguments(call), result)
                in NATIVE_METHODS -> invokePlayer(call.method, arguments(call), result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            Log.e(TAG, "Method ${call.method} failed", error)
            result.error(
                "ERIKA_ERROR",
                error.message ?: "Erika Android method ${call.method} failed",
                null,
            )
        }
    }

    private fun getImageCapabilities(result: MethodChannel.Result) {
        val policy = imagePolicy
        result.success(
            mapOf(
                "sdrDecodeSupported" to true,
                "hdrSurfaceSupported" to if (android.os.Build.VERSION.SDK_INT >= 24) {
                    activity?.display?.isHdr == true
                } else {
                    false
                },
                "networkSourceSupported" to false,
                "activeBackend" to "software",
                "maxEncodedBytes" to policy.maxEncodedBytes,
                "maxSourcePixels" to policy.maxSourcePixels,
                "maxOutputPixels" to policy.maxOutputPixels,
                "maxConcurrentDecodes" to policy.maxConcurrentDecodes,
            ),
        )
    }

    private fun configureImagePipeline(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val policy = AndroidImagePolicy(
            maxEncodedBytes = arguments.requiredLong("maxEncodedBytes"),
            maxSourcePixels = arguments.requiredLong("maxSourcePixels"),
            maxOutputPixels = arguments.requiredLong("maxOutputPixels"),
            maxPacketsBeforeFrame = arguments.requiredInt("maxPacketsBeforeFrame"),
            decodeTimeoutMillis = arguments.requiredLong("decodeTimeoutMillis"),
            maxQueuedDecodes = arguments.requiredInt("maxQueuedDecodes"),
            maxConcurrentDecodes = arguments.requiredInt("maxConcurrentDecodes"),
        )
        validateImagePolicy(policy)
        check(imageDecodeJobsByDartOperationId.isEmpty()) {
            "cannot reconfigure the image pipeline while decode jobs are active"
        }
        val previous = imageDecodeExecutor
        imagePolicy = policy
        imageDecodeExecutor = newImageDecodeExecutor(policy)
        previous.shutdown()
        result.success(null)
    }

    private fun decodeHdrImage(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val policy = imagePolicy
        val dartOperationId = arguments.requiredLong("operationId")
        val path = arguments["path"] as? String
            ?: throw IllegalArgumentException("path is required")
        val maxWidth = (arguments["cacheWidth"] as? Number)?.toInt() ?: 0
        val maxHeight = (arguments["cacheHeight"] as? Number)?.toInt() ?: 0
        require(dartOperationId > 0) { "operationId must be positive" }
        require(maxWidth >= 0 && maxHeight >= 0) { "cache dimensions cannot be negative" }
        val job = AndroidImageDecodeJob(
            dartOperationId,
            nextNativeImageOperationId(),
            engineAttachmentGeneration,
            result,
        )
        synchronized(imageOwnershipLock) {
            if (hdrImageDecodeReserved || hdrImageHandles.isNotEmpty()) {
                throw AndroidImageDecodeException(10, "another HDR image session is active")
            }
            hdrImageDecodeReserved = true
            job.ownsHdrReservation.set(true)
        }
        if (imageDecodeJobsByDartOperationId.putIfAbsent(dartOperationId, job) != null) {
            releaseHdrImageDecodeReservation(job)
            error("operationId is already active")
        }
        try {
            job.future = imageDecodeExecutor.submit {
                job.started.set(true)
                if (job.cancelled.get()) {
                    imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
                    releaseHdrImageDecodeReservation(job)
                    return@submit
                }
                imageDecodeInflight.incrementAndGet()
                var handle = 0L
                try {
                    handle = ErikaNative.nativeDecodeImage(
                        job.nativeOperationId,
                        File(path).absolutePath,
                        maxWidth,
                        maxHeight,
                        policy.maxEncodedBytes,
                        policy.maxSourcePixels,
                        policy.maxOutputPixels,
                        policy.maxPacketsBeforeFrame,
                        policy.decodeTimeoutMillis,
                    )
                    if (handle == 0L) throw AndroidImageDecodeException(
                        ErikaNative.nativeLastImageErrorKind(), ErikaNative.nativeLastError(),
                    )
                    imageActiveHandles.incrementAndGet()
                    val response = NativeJson.decodeResponse(ErikaNative.nativeImageMetadata(handle))
                    if (!response.ok) throw AndroidImageDecodeException(
                        ErikaNative.nativeLastImageErrorKind(), response.error.orEmpty(),
                    )
                    @Suppress("UNCHECKED_CAST")
                    val metadata = response.value as Map<String, Any?>
                    imageDecodeCount.incrementAndGet()
                    if (job.cancelled.get()) return@submit
                    synchronized(imageOwnershipLock) {
                        if (!imageSubsystemClosing && attachedToEngine &&
                            job.engineGeneration == engineAttachmentGeneration &&
                            completeImageJob(job, metadata + mapOf("imageId" to handle))
                        ) {
                            hdrImageHandles.add(handle)
                            handle = 0L
                        }
                    }
                } catch (error: Throwable) {
                    completeImageJob(job, error = error)
                } finally {
                    if (handle != 0L) {
                        NativeJson.decodeResponse(ErikaNative.nativeDestroyImage(handle))
                        imageActiveHandles.decrementAndGet()
                    }
                    imageDecodeInflight.decrementAndGet()
                    imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
                    releaseHdrImageDecodeReservation(job)
                }
            }
        } catch (error: RejectedExecutionException) {
            imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
            releaseHdrImageDecodeReservation(job)
            completeImageJob(job, error = error)
        }
    }

    private fun disposeHdrImage(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val imageId = arguments.requiredLong("imageId")
        val callGeneration = engineAttachmentGeneration
        val cleanupExecutor = imageCleanupExecutor
        val resultHandler = mainHandler
        if (!hdrImageHandles.contains(imageId)) {
            result.success(null)
            return
        }
        if (!hdrImagesDisposing.add(imageId)) {
            result.error("ERIKA_IMAGE_ERROR", "image cleanup is already active", mapOf("kind" to 10))
            return
        }
        val destroy = {
            ErikaNative.nativeDetachImageSurface(imageId)
            val response = NativeJson.decodeResponse(ErikaNative.nativeDestroyImage(imageId))
            if (response.ok && hdrImageHandles.remove(imageId)) imageActiveHandles.decrementAndGet()
            hdrImagesDisposing.remove(imageId)
            response
        }
        try {
            cleanupExecutor.execute {
                val response = destroy()
                resultHandler.post {
                    if (attachedToEngine && callGeneration == engineAttachmentGeneration) {
                        if (response.ok) result.success(null)
                        else result.error("ERIKA_IMAGE_ERROR", response.error, mapOf("kind" to 8))
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            hdrImagesDisposing.remove(imageId)
            result.error("ERIKA_IMAGE_ERROR", "image cleanup is closing", mapOf("kind" to 10))
        }
    }

    internal fun attachHdrImageSurface(
        imageId: Long,
        surface: android.view.Surface,
        width: Int,
        height: Int,
        extendedLinear: Boolean,
        fallbackReason: Int,
        directComposition: Boolean,
        viewId: Int,
        engineGeneration: Long,
        surfaceGeneration: Long,
        callback: (NativeResponse) -> Unit,
    ) {
        if (imageSubsystemClosing || engineGeneration != engineAttachmentGeneration) {
            callback(NativeResponse(false, 3, "image subsystem is closing", null))
            return
        }
        val surfaceToken = HdrImageSurfaceGeneration(engineGeneration, surfaceGeneration)
        synchronized(imageOwnershipLock) {
            hdrImageSurfaceGenerations[viewId] = surfaceToken
        }
        val surfaceExecutor = imageSurfaceExecutor
        try { surfaceExecutor.execute {
            if (imageSubsystemClosing || !attachedToEngine || engineGeneration != engineAttachmentGeneration) return@execute
            val ownerToken = HdrImageViewOwner(viewId, engineGeneration, surfaceGeneration)
            val owner = synchronized(imageOwnershipLock) {
                if (hdrImageSurfaceGenerations[viewId] != surfaceToken) return@execute
                hdrImageViewOwners.putIfAbsent(imageId, ownerToken)
            }
            if (owner != null && owner != ownerToken) {
                mainHandler.post { callback(NativeResponse(false, 3, "image is attached to another view", null)) }
                return@execute
            }
            val response = NativeJson.decodeResponse(
                ErikaNative.nativeAttachImageSurface(
                    imageId, surface, width, height, 1.0, extendedLinear, directComposition, 4f,
                    fallbackReason,
                ),
            )
            val stillCurrent = synchronized(imageOwnershipLock) {
                hdrImageSurfaceGenerations[viewId] == surfaceToken &&
                    hdrImageViewOwners[imageId] == ownerToken
            }
            val rendered = if (response.ok && stillCurrent) {
                NativeJson.decodeResponse(ErikaNative.nativeRenderImageSurface(imageId))
            } else response
            mainHandler.post {
                if (
                    attachedToEngine &&
                    engineGeneration == engineAttachmentGeneration &&
                    hdrImageViewOwners[imageId] == ownerToken
                ) callback(rendered)
            }
        } } catch (_: RejectedExecutionException) {
            callback(NativeResponse(false, 3, "image surface queue is closed", null))
        }
    }

    internal fun detachHdrImageSurface(
        imageId: Long,
        viewId: Int,
        engineGeneration: Long,
        surfaceGeneration: Long,
        completion: (() -> Unit)? = null,
    ) {
        if (engineGeneration != engineAttachmentGeneration) { completion?.invoke(); return }
        val surfaceToken = HdrImageSurfaceGeneration(engineGeneration, surfaceGeneration)
        val shouldDetach = synchronized(imageOwnershipLock) {
            hdrImageSurfaceGenerations[viewId] = surfaceToken
            val owner = hdrImageViewOwners[imageId]
            if (
                owner != null &&
                owner.viewId == viewId &&
                owner.engineGeneration == engineGeneration &&
                owner.surfaceGeneration < surfaceGeneration
            ) {
                hdrImageViewOwners.remove(imageId, owner)
            } else {
                false
            }
        }
        if (!::imageSurfaceExecutor.isInitialized) {
            completion?.invoke()
            return
        }
        val surfaceExecutor = imageSurfaceExecutor
        try {
            surfaceExecutor.execute {
            if (shouldDetach) {
                NativeJson.decodeResponse(ErikaNative.nativeDetachImageSurface(imageId))
            }
            completion?.invoke()
            }
        } catch (_: RejectedExecutionException) {
            completion?.invoke()
        }
    }

    internal fun resizeHdrImageSurface(
        imageId: Long,
        viewId: Int,
        engineGeneration: Long,
        surfaceGeneration: Long,
        width: Int,
        height: Int,
    ) {
        if (engineGeneration != engineAttachmentGeneration) return
        if (!::imageSurfaceExecutor.isInitialized) return
        val surfaceExecutor = imageSurfaceExecutor
        try {
            surfaceExecutor.execute {
                val surfaceToken = HdrImageSurfaceGeneration(engineGeneration, surfaceGeneration)
                val ownerToken = HdrImageViewOwner(viewId, engineGeneration, surfaceGeneration)
                if (
                    attachedToEngine &&
                    engineGeneration == engineAttachmentGeneration &&
                    hdrImageSurfaceGenerations[viewId] == surfaceToken &&
                    hdrImageViewOwners[imageId] == ownerToken
                ) {
                    val resized = NativeJson.decodeResponse(
                        ErikaNative.nativeResizeImageSurface(imageId, width, height),
                    )
                    val rendered = if (resized.ok) {
                        NativeJson.decodeResponse(ErikaNative.nativeRenderImageSurface(imageId))
                    } else {
                        resized
                    }
                    if (!rendered.ok) {
                        Log.e(TAG, "Unable to resize HDR image $imageId: ${rendered.error}")
                        mainHandler.post {
                            if (
                                attachedToEngine &&
                                engineGeneration == engineAttachmentGeneration &&
                                hdrImageViewOwners[imageId] == ownerToken
                            ) {
                                reportHdrImageSurfaceEvent(
                                    viewId,
                                    imageId,
                                    engineGeneration,
                                    rendered,
                                )
                            }
                        }
                    }
                }
            }
        } catch (_: RejectedExecutionException) { }
    }

    internal fun registerHdrImageView(viewId: Int, generation: Long) {
        if (attachedToEngine && generation == engineAttachmentGeneration) {
            hdrImageViews[viewId] = generation
            hdrImageSurfaceGenerations[viewId] = HdrImageSurfaceGeneration(generation, 0)
        }
    }
    internal fun unregisterHdrImageView(viewId: Int, generation: Long) {
        hdrImageViews.remove(viewId, generation)
        hdrImageSurfaceGenerations.computeIfPresent(viewId) { _, token ->
            if (token.engineGeneration == generation) null else token
        }
    }

    internal fun reportHdrImageSurfaceEvent(
        viewId: Int,
        imageId: Long,
        engineGeneration: Long,
        response: NativeResponse,
    ) {
        if (
            !attachedToEngine ||
            engineGeneration != engineAttachmentGeneration ||
            hdrImageViews[viewId] != engineGeneration
        ) return
        methodChannel.invokeMethod(
            "imageSurfaceEvent",
            mapOf(
                "viewId" to viewId,
                "imageId" to imageId,
                "ok" to response.ok,
                "error" to response.error,
                "value" to response.value,
            ),
        )
    }

    private data class HdrImageViewOwner(
        val viewId: Int,
        val engineGeneration: Long,
        val surfaceGeneration: Long,
    )

    private data class HdrImageSurfaceGeneration(
        val engineGeneration: Long,
        val surfaceGeneration: Long,
    )

    private fun decodeSdrTexture(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) = decodeImageTexture(arguments, result, automaticHdr = false)

    private fun decodeImage(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) = decodeImageTexture(arguments, result, automaticHdr = true)

    private fun decodeImageTexture(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
        automaticHdr: Boolean,
    ) {
        val policy = imagePolicy
        val dartOperationId = arguments.requiredLong("operationId")
        val path = arguments["path"] as? String
            ?: throw IllegalArgumentException("path is required")
        val maxWidth = (arguments["cacheWidth"] as? Number)?.toInt() ?: 0
        val maxHeight = (arguments["cacheHeight"] as? Number)?.toInt() ?: 0
        require(dartOperationId > 0) { "operationId must be positive" }
        require(maxWidth >= 0 && maxHeight >= 0) { "cache dimensions cannot be negative" }
        val job = AndroidImageDecodeJob(
            dartOperationId,
            nextNativeImageOperationId(),
            engineAttachmentGeneration,
            result,
        )
        check(imageDecodeJobsByDartOperationId.putIfAbsent(dartOperationId, job) == null) {
            "image decode operation $dartOperationId is already active"
        }
        try {
            job.future = imageDecodeExecutor.submit {
                if (job.cancelled.get()) return@submit
                imageDecodeInflight.incrementAndGet()
                var handle = 0L
                try {
                    val file = File(path)
                    if (!file.isFile) {
                        throw AndroidImageDecodeException(
                            IMAGE_ERROR_SOURCE,
                            "cached image file does not exist",
                        )
                    }
                    if (file.length() > policy.maxEncodedBytes) {
                        throw AndroidImageDecodeException(
                            IMAGE_ERROR_RESOURCE_LIMIT,
                            "encoded image exceeds the ${policy.maxEncodedBytes}-byte limit",
                        )
                    }
                    if (job.cancelled.get()) return@submit
                    handle = ErikaNative.nativeDecodeImage(
                        job.nativeOperationId,
                        file.absolutePath,
                        maxWidth,
                        maxHeight,
                        policy.maxEncodedBytes,
                        policy.maxSourcePixels,
                        policy.maxOutputPixels,
                        policy.maxPacketsBeforeFrame,
                        policy.decodeTimeoutMillis,
                    )
                    if (handle == 0L) {
                        throw AndroidImageDecodeException(
                            ErikaNative.nativeLastImageErrorKind(),
                            ErikaNative.nativeLastError(),
                        )
                    }
                    imageActiveHandles.incrementAndGet()
                    if (job.cancelled.get()) return@submit
                    val metadataResponse = NativeJson.decodeResponse(
                        ErikaNative.nativeImageMetadata(handle),
                    )
                    if (!metadataResponse.ok) {
                        throw AndroidImageDecodeException(
                            ErikaNative.nativeLastImageErrorKind(),
                            metadataResponse.error ?: "unable to read image metadata",
                        )
                    }
                    @Suppress("UNCHECKED_CAST")
                    val metadata = metadataResponse.value as? Map<String, Any?>
                        ?: throw IllegalStateException("native image metadata was not an object")
                    val sourceWidth = (metadata["width"] as Number).toInt()
                    val sourceHeight = (metadata["height"] as Number).toInt()
                    val sourceDynamicRange = (metadata["sourceDynamicRange"] as? Number)?.toInt() ?: 0
                    val hdrDisplaySupported = android.os.Build.VERSION.SDK_INT >= 24 &&
                        activity?.display?.isHdr == true
                    if (automaticHdr && sourceDynamicRange >= 2 && hdrDisplaySupported) {
                        val deliveredAsHdr = synchronized(imageOwnershipLock) {
                            if (hdrImageDecodeReserved || hdrImageHandles.isNotEmpty() ||
                                imageSubsystemClosing || !attachedToEngine ||
                                job.engineGeneration != engineAttachmentGeneration
                            ) {
                                false
                            } else if (completeImageJob(
                                    job,
                                    metadata + mapOf(
                                        "presentation" to "hdr",
                                        "imageId" to handle,
                                    ),
                                )
                            ) {
                                hdrImageHandles.add(handle)
                                true
                            } else {
                                false
                            }
                        }
                        if (deliveredAsHdr) {
                            imageDecodeCount.incrementAndGet()
                            handle = 0L
                            return@submit
                        }
                    }
                    val extent = boundedImageExtent(
                        sourceWidth,
                        sourceHeight,
                        maxWidth,
                        maxHeight,
                    )
                    if (extent.first.toLong() * extent.second.toLong() > policy.maxOutputPixels) {
                        throw AndroidImageDecodeException(
                            IMAGE_ERROR_RESOURCE_LIMIT,
                            "decoded image exceeds the ${policy.maxOutputPixels}-pixel output limit",
                        )
                    }
                    val texture = createSdrImageTexture(
                        handle,
                        extent.first,
                        extent.second,
                        job.engineGeneration,
                    )
                    handle = 0L
                    if (job.cancelled.get()) {
                        disposeSdrImageTexture(texture)
                        return@submit
                    }
                    imageDecodeCount.incrementAndGet()
                    val delivered = completeImageJob(
                        job,
                        value = metadata + mapOf(
                            "presentation" to "sdr",
                            "sourceWidth" to sourceWidth,
                            "sourceHeight" to sourceHeight,
                            "width" to extent.first,
                            "height" to extent.second,
                            "textureId" to texture.textureId,
                        ),
                    )
                    if (!delivered) disposeSdrImageTexture(texture)
                } catch (error: Throwable) {
                    completeImageJob(job, error = error)
                } finally {
                    if (handle != 0L) {
                        NativeJson.decodeResponse(ErikaNative.nativeDestroyImage(handle))
                        imageActiveHandles.decrementAndGet()
                    }
                    imageDecodeInflight.decrementAndGet()
                    imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
                }
            }
        } catch (error: RejectedExecutionException) {
            imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
            completeImageJob(job, error = error)
        }
    }

    private fun createSdrImageTexture(
        handle: Long,
        width: Int,
        height: Int,
        engineGeneration: Long,
    ): AndroidSdrImageTexture {
        val ready = CountDownLatch(1)
        val registrationLock = Any()
        var created: AndroidSdrImageTexture? = null
        var creationError: Throwable? = null
        var registrationClosed = false
        mainHandler.post {
            synchronized(registrationLock) {
                if (registrationClosed) {
                    ready.countDown()
                    return@post
                }
                try {
                    check(attachedToEngine && !imageSubsystemClosing &&
                        engineGeneration == engineAttachmentGeneration) {
                        "image subsystem is closing"
                    }
                    val producer = textureRegistry.createSurfaceProducer()
                    producer.setSize(width, height)
                    val texture = AndroidSdrImageTexture(
                        this,
                        producer,
                        handle,
                        width,
                        height,
                        engineGeneration,
                    )
                    sdrImageTextures[texture.textureId] = texture
                    created = texture
                } catch (error: Throwable) {
                    creationError = error
                } finally {
                    registrationClosed = true
                    ready.countDown()
                }
            }
        }
        if (!ready.await(2, TimeUnit.SECONDS)) {
            val timedOut = synchronized(registrationLock) {
                if (created == null && creationError == null) {
                    registrationClosed = true
                    true
                } else {
                    false
                }
            }
            if (timedOut) {
                throw AndroidImageDecodeException(
                    IMAGE_ERROR_BUSY,
                    "timed out registering the Flutter image texture",
                )
            }
        }
        creationError?.let { throw it }
        val texture = created ?: throw AndroidImageDecodeException(
            IMAGE_ERROR_INTERNAL,
            "Flutter image texture registration failed",
        )
        try {
            attachAndRenderSdrImageTexture(texture)
            mainHandler.post {
                if (!texture.disposed.get()) texture.producer.setCallback(texture)
            }
            return texture
        } catch (error: Throwable) {
            abandonSdrImageTextureRegistration(texture)
            throw error
        }
    }

    private fun attachAndRenderSdrImageTexture(texture: AndroidSdrImageTexture) {
        if (texture.disposed.get() || imageSubsystemClosing ||
            texture.engineGeneration != engineAttachmentGeneration) {
            throw AndroidImageDecodeException(IMAGE_ERROR_CANCELLED, "image texture is stale")
        }
        if (!texture.surfaceAttached.get()) {
            val attached = NativeJson.decodeResponse(
                ErikaNative.nativeAttachImageSurface(
                    texture.handle,
                    texture.producer.surface,
                    texture.width,
                    texture.height,
                    1.0,
                    false,
                    false,
                    1f,
                    0,
                ),
            )
            if (!attached.ok) {
                throw AndroidImageDecodeException(
                    ErikaNative.nativeLastImageErrorKind(),
                    attached.error ?: "unable to attach the SDR image texture",
                )
            }
            texture.surfaceAttached.set(true)
        }
        val rendered = NativeJson.decodeResponse(
            ErikaNative.nativeRenderImageSurface(texture.handle),
        )
        if (!rendered.ok) {
            if (texture.surfaceAttached.compareAndSet(true, false)) {
                ErikaNative.nativeDetachImageSurface(texture.handle)
            }
            throw AndroidImageDecodeException(
                ErikaNative.nativeLastImageErrorKind(),
                rendered.error ?: "unable to render the SDR image texture",
            )
        }
    }

    internal fun renderSdrImageTexture(texture: AndroidSdrImageTexture) {
        if (texture.disposed.get() || imageSubsystemClosing) return
        try {
            imageSurfaceExecutor.execute {
                try {
                    attachAndRenderSdrImageTexture(texture)
                } catch (error: Throwable) {
                    Log.e(TAG, "Unable to restore SDR texture ${texture.textureId}", error)
                }
            }
        } catch (_: RejectedExecutionException) {
            // Engine teardown owns the texture from this point.
        }
    }

    internal fun detachSdrImageTextureSurface(texture: AndroidSdrImageTexture) {
        if (texture.disposed.get()) return
        try {
            imageSurfaceExecutor.execute {
                if (texture.surfaceAttached.compareAndSet(true, false)) {
                    ErikaNative.nativeDetachImageSurface(texture.handle)
                }
            }
        } catch (_: RejectedExecutionException) {
            // Engine teardown owns the texture from this point.
        }
    }

    private fun abandonSdrImageTextureRegistration(texture: AndroidSdrImageTexture) {
        if (!texture.disposed.compareAndSet(false, true)) return
        sdrImageTextures.remove(texture.textureId, texture)
        if (texture.surfaceAttached.compareAndSet(true, false)) {
            ErikaNative.nativeDetachImageSurface(texture.handle)
        }
        mainHandler.post {
            texture.producer.setCallback(null)
            texture.producer.release()
        }
    }

    private fun disposeSdrTexture(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val textureId = arguments.requiredLong("textureId")
        val texture = sdrImageTextures[textureId]
        if (texture == null) {
            result.success(null)
            return
        }
        val callGeneration = engineAttachmentGeneration
        disposeSdrImageTexture(texture) { response ->
            if (!attachedToEngine || callGeneration != engineAttachmentGeneration) return@disposeSdrImageTexture
            if (response.ok) result.success(null)
            else result.error(
                "ERIKA_IMAGE_ERROR",
                response.error ?: "unable to dispose SDR image texture",
                mapOf("kind" to IMAGE_ERROR_RENDERER),
            )
        }
    }

    private fun disposeSdrImageTexture(
        texture: AndroidSdrImageTexture,
        completion: ((NativeResponse) -> Unit)? = null,
    ) {
        if (!texture.disposed.compareAndSet(false, true)) {
            completion?.invoke(NativeResponse(true, 0, null, null))
            return
        }
        sdrImageTextures.remove(texture.textureId, texture)
        mainHandler.post { texture.producer.setCallback(null) }
        try {
            imageSurfaceExecutor.execute {
                if (texture.surfaceAttached.compareAndSet(true, false)) {
                    ErikaNative.nativeDetachImageSurface(texture.handle)
                }
                val response = NativeJson.decodeResponse(
                    ErikaNative.nativeDestroyImage(texture.handle),
                )
                if (response.ok) imageActiveHandles.decrementAndGet()
                mainHandler.post {
                    texture.producer.release()
                    completion?.invoke(response)
                }
            }
        } catch (_: RejectedExecutionException) {
            mainHandler.post {
                texture.producer.release()
                completion?.invoke(
                    NativeResponse(false, IMAGE_ERROR_BUSY, "image cleanup is closing", null),
                )
            }
        }
    }

    private fun cancelImageDecode(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val dartOperationId = arguments.requiredLong("operationId")
        imageDecodeJobsByDartOperationId[dartOperationId]?.let { job ->
            job.cancelled.set(true)
            ErikaNative.nativeCancelImageDecode(job.nativeOperationId)
            val future = job.future
            if (future is Runnable && imageDecodeExecutor.remove(future)) {
                imageQueuedCancelled.incrementAndGet()
                releaseHdrImageDecodeReservation(job)
            }
            job.future?.cancel(true)
            imageDecodeExecutor.purge()
            completeImageJob(job, error = CancellationException("image decode was cancelled"))
            imageDecodeJobsByDartOperationId.remove(dartOperationId, job)
        }
        result.success(null)
    }

    private fun releaseHdrImageDecodeReservation(job: AndroidImageDecodeJob) {
        if (!job.ownsHdrReservation.compareAndSet(true, false)) return
        synchronized(imageOwnershipLock) {
            hdrImageDecodeReserved = false
        }
    }

    private fun getImageDiagnostics(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "queued" to if (::imageDecodeExecutor.isInitialized) {
                    imageDecodeExecutor.queue.size
                } else {
                    0
                },
                "inflight" to imageDecodeInflight.get(),
                "decodeCount" to imageDecodeCount.get(),
                "queuedCancelled" to imageQueuedCancelled.get(),
                "nativeHandleCount" to imageActiveHandles.get(),
                "sdrTextureCount" to sdrImageTextures.size,
                "playerCount" to players.size,
                "platformViewCount" to videoViews.size + hdrImageViews.size,
            ),
        )
    }

    private fun completeImageJob(
        job: AndroidImageDecodeJob,
        value: Map<String, Any?>? = null,
        error: Throwable? = null,
    ): Boolean {
        if (!job.completed.compareAndSet(false, true)) return false
        mainHandler.post {
            if (!attachedToEngine || job.engineGeneration != engineAttachmentGeneration) {
                return@post
            }
            if (error == null) {
                job.result.success(value)
            } else {
                val kind = (error as? AndroidImageDecodeException)?.kind
                    ?: if (error is CancellationException) {
                        IMAGE_ERROR_CANCELLED
                    } else if (error is RejectedExecutionException) {
                        IMAGE_ERROR_BUSY
                    } else {
                        IMAGE_ERROR_INTERNAL
                    }
                job.result.error(
                    "ERIKA_IMAGE_ERROR",
                    error.message ?: "Erika image decode failed",
                    mapOf("kind" to kind),
                )
            }
        }
        return true
    }

    internal fun registerVideoView(view: ErikaAndroidVideoView) {
        videoViews.put(view.viewId, view)?.takeIf { it !== view }?.dispose()
    }

    internal fun unregisterVideoView(view: ErikaAndroidVideoView) {
        if (videoViews[view.viewId] === view) {
            videoViews.remove(view.viewId)
        }
    }

    internal fun onPlayerRenderStateChanged() {
        refreshFrameScheduling()
    }

    internal fun reportSurfaceResponse(
        host: AndroidPlayerHost,
        operation: String,
        response: NativeResponse,
    ) {
        if (response.ok) {
            host.lastSurfaceError = null
            if (androidSurfaceOperationNeedsImmediateEventPoll(operation, responseOk = true)) {
                drainEvents(host)
            }
        } else {
            val signature = "$operation:${response.status}:${response.error.orEmpty()}"
            Log.e(
                TAG,
                "$operation failed for player ${host.handle}: status=${response.status} ${response.error.orEmpty()}",
            )
            if (host.lastSurfaceError != signature) {
                host.lastSurfaceError = signature
                enqueueHostError(
                    host,
                    operation,
                    response.status,
                    response.error ?: "$operation failed",
                    contentGeneration = null,
                )
            }
        }
        refreshFrameScheduling()
    }

    internal fun reportSurfaceRecoveryExhausted(
        host: AndroidPlayerHost,
        viewId: Int,
        operation: String,
        generation: Long,
        retryAttempts: Int,
        response: NativeResponse,
    ) {
        val failedAttempts = retryAttempts + 1
        val error = response.error ?: "$operation failed without a native error"
        Log.e(
            TAG,
            "surfaceRecoveryExhausted playerId=${host.handle} viewId=$viewId " +
                "operation=$operation generation=$generation " +
                "failedAttempts=$failedAttempts retryAttempts=$retryAttempts " +
                "status=${response.status} error=$error",
        )
        enqueueHostError(
            host,
            "surfaceRecovery",
            response.status,
            "$operation recovery exhausted after $failedAttempts failed attempts: $error",
            mapOf(
                "surfaceOperation" to operation,
                "surfaceViewId" to viewId,
                "surfaceRecoveryGeneration" to generation,
                "surfaceRecoveryFailedAttempts" to failedAttempts,
                "surfaceRecoveryRetryAttempts" to retryAttempts,
            ),
            contentGeneration = null,
        )
    }

    internal fun retirePlayerAfterSurfaceRecoveryExhausted(host: AndroidPlayerHost) {
        if (host.isDestroyed) {
            return
        }
        players.remove(host.handle, host)
        stopEventPollingIfIdle()
        Log.e(
            TAG,
            "Retiring player ${host.handle} after unrecoverable Android surface detach",
        )
        destroyPlayer(host)
    }

    private fun createPlayer(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val outputMode = arguments.int("outputMode") ?: 0
        val defaultHeadroom = if (outputMode == 2) 4f else 1f
        val edrHeadroom =
            (arguments.number("edrHeadroom")?.toFloat() ?: defaultHeadroom).coerceAtLeast(1f)
        val upscaler = arguments.int("upscaler") ?: arguments.int("lumaUpscaler") ?: 0
        val videoAlphaMode = arguments.int("videoAlphaMode") ?: 0
        val ownerThread = presenterThread
        val attachmentGeneration = engineAttachmentGeneration
        val posted = ownerThread.post {
            val createResult = runCatching {
                ErikaNative.nativeCreate(
                    outputMode,
                    edrHeadroom,
                    upscaler,
                    videoAlphaMode,
                )
            }
            val createFailure = createResult.exceptionOrNull()
            if (createFailure != null) {
                postPresenterCreateFailure(
                    ownerThread,
                    attachmentGeneration,
                    result,
                    createFailure.message ?: "Erika Android presenter creation threw",
                    createFailure,
                )
                return@post
            }
            val createdHandle = createResult.getOrThrow()
            val error = if (createdHandle == 0L) {
                runCatching(ErikaNative::nativeLastError).getOrNull().orEmpty()
            } else {
                ""
            }
            if (createdHandle == 0L) {
                postPresenterCreateFailure(
                    ownerThread,
                    attachmentGeneration,
                    result,
                    error.ifBlank { "Erika C ABI did not provide a presenter creation error" },
                )
                return@post
            }
            if (!presenterCreates.registerIfCurrent(
                    createdHandle,
                    ownerThread,
                    attachmentGeneration,
                )
            ) {
                ErikaNative.nativeDestroy(createdHandle)
                return@post
            }
            postMainSafely(
                source = "presenter create completion",
                onFailure = { callbackError ->
                    retireFailedPresenterCreate(createdHandle, ownerThread)
                    runCatching {
                        result.error(
                            "ERIKA_ERROR",
                            callbackError.message
                                ?: "Erika Android presenter creation callback failed",
                            mapOf("stage" to "presenter_create_completion"),
                        )
                    }
                },
            ) {
                if (!presenterCreates.claimIfCurrent(
                        createdHandle,
                        ownerThread,
                        attachmentGeneration,
                    )
                ) {
                    return@postMainSafely
                }
                val host = AndroidPlayerHost(
                    createdHandle,
                    outputMode,
                    arguments["allowBackgroundPlayback"] == true,
                    ownerThread,
                )
                players[createdHandle] = host
                requestEventPoll(immediate = true)
                runCatching { result.success(createdHandle) }
                    .onFailure { callbackError ->
                        players.remove(createdHandle, host)
                        destroyPlayer(host)
                        throw callbackError
                    }
            }
        }
        if (!posted) {
            result.error(
                "ERIKA_ERROR",
                "Android presenter thread is unavailable",
                mapOf("stage" to "presenter_create"),
            )
        }
    }

    private fun postPresenterCreateFailure(
        ownerThread: AndroidPresenterThread,
        attachmentGeneration: Long,
        result: MethodChannel.Result,
        reason: String,
        cause: Throwable? = null,
    ) {
        Log.e(TAG, "Erika Android presenter creation failed: $reason", cause)
        postMainSafely("presenter create failure") {
            if (!presenterCreates.isCurrent(ownerThread, attachmentGeneration)) {
                return@postMainSafely
            }
            result.error(
                "ERIKA_ERROR",
                "Erika Android presenter creation failed: $reason",
                mapOf("stage" to "presenter_create", "reason" to reason),
            )
        }
    }

    private fun retireFailedPresenterCreate(
        handle: Long,
        ownerThread: AndroidPresenterThread,
    ) {
        if (!presenterCreates.abandon(handle, ownerThread)) {
            return
        }
        if (ownerThread.isOwnerThread) {
            ErikaNative.nativeDestroy(handle)
        } else if (!ownerThread.post { ErikaNative.nativeDestroy(handle) }) {
            Log.e(TAG, "Unable to retire failed presenter $handle on its owner thread")
        }
    }

    private fun disposePlayer(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val completionAttempted = AtomicBoolean(false)
        val queued = beginDestroyPlayer(host) { destruction ->
            postMainSafely(
                source = "dispose completion",
                onFailure = { error ->
                    if (completionAttempted.compareAndSet(false, true)) {
                        runCatching {
                            result.error(
                                "ERIKA_ERROR",
                                error.message ?: "Android dispose completion failed",
                                mapOf("stage" to "dispose_completion"),
                            )
                        }
                    }
                },
            ) {
                if (!completionAttempted.compareAndSet(false, true)) {
                    return@postMainSafely
                }
                destruction.fold(
                    onSuccess = { result.success(null) },
                    onFailure = { error ->
                        result.error(
                            "ERIKA_ERROR",
                            error.message ?: "Unable to destroy Erika Android player",
                            mapOf("stage" to "presenter_destroy"),
                        )
                    },
                )
            }
        }
        if (queued) {
            players.remove(host.handle, host)
            stopEventPollingIfIdle()
        } else if (completionAttempted.compareAndSet(false, true)) {
            result.error(
                "ERIKA_ERROR",
                "Android presenter thread rejected player destruction",
                mapOf("stage" to "presenter_destroy", "reason" to "queue_rejected"),
            )
        }
    }

    private fun destroyPlayer(host: AndroidPlayerHost) {
        if (!beginDestroyPlayer(host) { result ->
                result.onFailure { error ->
                    Log.e(TAG, "Unable to destroy Erika player ${host.handle}", error)
                }
            }
        ) {
            Log.e(TAG, "Unable to queue Erika player ${host.handle} destruction")
        }
    }

    private fun beginDestroyPlayer(
        host: AndroidPlayerHost,
        onComplete: (Result<Unit>) -> Unit,
    ): Boolean {
        failAllPendingPlayResults(
            host,
            IllegalStateException("Erika player ${host.handle} was disposed before play completed"),
        )
        host.cancelPlaybackIntent()
        abandonAudioFocusIfIdle()
        val queued = host.destroyAsync { destruction ->
            postMainSafely(
                source = "player destroy finalization",
                onFailure = { error -> onComplete(Result.failure(error)) },
            ) {
                host.finishDestroyOnMain()
                onComplete(destruction)
            }
        }
        if (!queued) {
            refreshFrameScheduling()
            return false
        }
        if (activeMediaPlayerId == host.handle) {
            activeMediaPlayerId = null
            ErikaMediaCommandReceiver.deactivate(this)
            mediaSession.clear(host.handle)
        }
        refreshFrameScheduling()
        return queued
    }

    private fun attachView(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val viewId = arguments.requiredInt("viewId")
        val view = videoViews[viewId]
        if (view == null) {
            result.error("ERIKA_ERROR", "Erika Android video view $viewId was not found", null)
            return
        }
        if (view.isExtendedLinearSurface != host.requiresExtendedLinearSurface) {
            result.error(
                "ERIKA_ERROR",
                "Erika Android player ${host.handle} requires " +
                    if (host.requiresExtendedLinearSurface) {
                        "an extended-linear SurfaceView"
                    } else {
                        "an SDR TextureView"
                    },
                null,
            )
            return
        }
        view.bindAsync(host) { response ->
            deliverSurfaceMethodResult("attachView", result, response)
        }
    }

    private fun detachView(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val viewId = arguments.requiredInt("viewId")
        val view = videoViews[viewId]
        if (view != null && host.attachedView === view) {
            view.unbindAsync(host) { response ->
                deliverSurfaceMethodResult("detachView", result, response)
            }
        } else {
            result.success(null)
        }
    }

    private fun attachOverlay(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val view = host.attachedView
            ?: videoViews.values.lastOrNull { candidate ->
                candidate.isExtendedLinearSurface == host.requiresExtendedLinearSurface &&
                    players.values.none { it.attachedView === candidate }
            }
        if (view == null) {
            result.error(
                "ERIKA_ERROR",
                "Android window-overlay playback requires an Erika TextureView platform view",
                null,
            )
            return
        }
        view.bindAsync(host) { response ->
            deliverSurfaceMethodResult("attachOverlay", result, response, view.viewId)
        }
    }

    private fun detachOverlay(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val view = host.attachedView
        if (view == null) {
            result.success(null)
            return
        }
        view.unbindAsync(host) { response ->
            deliverSurfaceMethodResult("detachOverlay", result, response)
        }
    }

    private fun setOverlayFrame(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val visible = arguments["visible"] as? Boolean ?: true
        val debugLabel = arguments["debugLabel"] as? String
        val requestedViewId = arguments.int("viewId")?.takeIf { it >= 0 }
        val view = if (requestedViewId != null) {
            val requestedView = videoViews[requestedViewId]
            if (requestedView == null) {
                result.error(
                    "ERIKA_ERROR",
                    "Erika Android video view $requestedViewId was not found",
                    mapOf("stage" to "setOverlayFrame", "viewId" to requestedViewId),
                )
                return
            }
            if (host.attachedView !== requestedView) {
                result.error(
                    "ERIKA_ERROR",
                    "Erika Android video view $requestedViewId is not attached to player ${host.handle}",
                    mapOf("stage" to "setOverlayFrame", "viewId" to requestedViewId),
                )
                return
            }
            requestedView
        } else {
            host.attachedView
        }
        if (view == null) {
            if (!visible) {
                result.success(null)
                return
            }
            result.error(
                "ERIKA_ERROR",
                "Erika Android player ${host.handle} has no attached video view",
                mapOf("stage" to "setOverlayFrame"),
            )
            return
        }
        view.setFlutterManagedVisibility(visible, debugLabel)
        result.success(null)
    }

    private fun captureFrame(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        val requestedViewId = arguments.int("viewId")
        val view = if (requestedViewId != null) {
            val requestedView = videoViews[requestedViewId]
            if (requestedView == null) {
                result.error(
                    "ERIKA_ERROR",
                    "Erika Android video view $requestedViewId was not found",
                    mapOf("stage" to "screenshot", "viewId" to requestedViewId),
                )
                return
            }
            if (host.attachedView !== requestedView) {
                result.error(
                    "ERIKA_ERROR",
                    "Erika Android video view $requestedViewId is not attached to player ${host.handle}",
                    mapOf("stage" to "screenshot", "viewId" to requestedViewId),
                )
                return
            }
            requestedView
        } else {
            host.attachedView
        }
        val width = arguments.int("width")?.takeIf { it > 0 }
            ?: view?.pixelWidth()?.takeIf { it > 0 }
        val height = arguments.int("height")?.takeIf { it > 0 }
            ?: view?.pixelHeight()?.takeIf { it > 0 }
        if (width == null || height == null) {
            result.error(
                "ERIKA_ERROR",
                "Screenshot width and height are required before an Android video surface is attached",
                null,
            )
            return
        }
        val posted = host.captureFrameAsync(width, height) { captured ->
            postMainSafely(
                source = "screenshot completion",
                onFailure = { error ->
                    runCatching {
                        result.error("ERIKA_ERROR", error.message, mapOf("stage" to "screenshot"))
                    }
                },
            ) {
                result.success(captured.getOrThrow())
            }
        }
        if (!posted) {
            result.error(
                "ERIKA_ERROR",
                "Android presenter thread is unavailable",
                mapOf("stage" to "screenshot"),
            )
        }
    }

    private fun invokePlayer(
        method: String,
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val host = player(arguments)
        val contentGeneration = when {
            method == "open" -> {
                val metadata = arguments["metadata"]
                if (metadata != null && metadata !is Map<*, *>) {
                    throw IllegalArgumentException("metadata must be a map")
                }
                host.prepareForOpen(
                    metadata?.let { androidMediaMetadata(arguments) },
                )
            }
            method in CONTENT_PREPARATION_INVALIDATION_METHODS ->
                host.currentContentGeneration
            else -> null
        }
        if (method == "play") {
            playWithAudioFocus(host, result)
            return
        }

        if (method in PLAYBACK_INTENT_CANCEL_METHODS) {
            host.cancelPlaybackIntent(forceNewGeneration = true)
            abandonAudioFocusIfIdle()
            refreshFrameScheduling()
        }
        val playbackIntentGeneration = method
            .takeIf(PLAYBACK_INTENT_CANCEL_METHODS::contains)
            ?.let { host.currentPlaybackIntentGeneration }

        if (method in CONTENT_PREPARATION_INVALIDATION_METHODS) {
            host.cancelContentPreparations("superseded_by_$method")
        }

        if (requiresAsyncContentPreparation(method, arguments)) {
            invokePlayerAfterContentPreparation(
                host,
                method,
                arguments,
                result,
                playbackIntentGeneration,
                contentGeneration,
            )
            return
        }

        val prepared = prepareNativeArguments(method, arguments)
        invokePreparedPlayer(
            host,
            method,
            prepared,
            result,
            playbackIntentGeneration,
            contentGeneration,
        )
    }

    private fun registerSubtitleMemoryFont(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val host = player(arguments)
        val data = arguments["data"] as? ByteArray
            ?: throw IllegalArgumentException("Missing byte array argument 'data'")
        val posted = host.registerSubtitleMemoryFontAsync(data) { response ->
            postMainSafely(
                source = "subtitle memory font completion",
                onFailure = { error ->
                    runCatching {
                        result.error(
                            "ERIKA_ERROR",
                            error.message,
                            mapOf("stage" to "register_subtitle_memory_font"),
                        )
                    }
                },
            ) {
                val nativeResponse = response.getOrThrow()
                if (nativeResponse.ok) {
                    host.requestRender()
                }
                complete(result, nativeResponse)
            }
        }
        if (!posted) {
            result.error(
                "ERIKA_ERROR",
                "Android presenter thread is unavailable",
                mapOf("stage" to "register_subtitle_memory_font"),
            )
        }
    }

    private fun invokePreparedPlayer(
        host: AndroidPlayerHost,
        method: String,
        prepared: PreparedNativeArguments,
        result: MethodChannel.Result,
        playbackIntentGeneration: Long?,
        contentGeneration: Long?,
    ) {
        val argumentsJson = try {
            NativeJson.encodeArguments(prepared.arguments)
        } catch (error: Throwable) {
            prepared.detachedFd?.let(::closeDetachedFileDescriptor)
            throw error
        }
        val completionAttempted = AtomicBoolean(false)
        val posted = presenterThread.post {
            playbackIntentGeneration?.let(host::markPlaybackIntentExecuted)
            val response = runCatching {
                if (host.isDestroyed) {
                    prepared.detachedFd?.let(::closeDetachedFileDescriptor)
                    throw IllegalStateException("Erika player ${host.handle} has been destroyed")
                }
                // Once nativeInvoke is entered, Rust owns every detached fd regardless of
                // the returned status and closes it either in the JNI bridge or source Drop.
                val rawResponse = try {
                    host.invokeEncodedRaw(
                        method,
                        argumentsJson,
                        prepared.detachedFd ?: NO_OWNED_FD,
                    )
                } catch (error: Throwable) {
                    // Disposal or symbol resolution can fail before Rust owns the fd.
                    if (androidNativeInvokeDidNotStart(error)) {
                        prepared.detachedFd?.let(::closeDetachedFileDescriptor)
                    }
                    throw error
                }
                // Decode only after the JNI ownership boundary. A malformed response must
                // never make Kotlin close an fd that Rust has already consumed.
                NativeJson.decodeResponse(rawResponse)
            }
            if (androidContentCommandEstablishedBoundary(
                    method = method,
                    responseDecoded = response.isSuccess,
                    responseOk = response.getOrNull()?.ok == true,
                )
            ) {
                contentGeneration?.let(host::markContentGenerationExecuted)
            }
            val events = pollEventsOnPresenterThread(host)
            postMainSafely(
                source = "async $method completion",
                onFailure = { error ->
                    if (completionAttempted.compareAndSet(false, true)) runCatching {
                        result.error(
                            "ERIKA_ERROR",
                            error.message ?: "Erika Android method $method failed",
                            mapOf("stage" to "main_completion", "method" to method),
                        )
                    }.onFailure { deliveryError ->
                        Log.w(TAG, "Unable to deliver failed Android $method result", deliveryError)
                    }
                },
            ) {
                if (players[host.handle] === host && !host.isDestroyed) {
                    processPolledEvents(events)
                }
                val nativeResponse = response.getOrElse { error ->
                    closeFailedNativeOpen(
                        host,
                        method,
                        contentGeneration,
                        "native_exception",
                    )
                    throw IllegalStateException(
                        error.message ?: "Erika Android method $method failed",
                        error,
                    )
                }
                if (!nativeResponse.ok) {
                    closeFailedNativeOpen(
                        host,
                        method,
                        contentGeneration,
                        "native_response_${nativeResponse.status}",
                    )
                }
                finishPreparedPlayerInvocation(
                    host,
                    method,
                    prepared,
                    nativeResponse,
                )
                // Keep delivery last so callback failures cannot strand the Dart Future,
                // and no work after delivery can cause a second completion attempt.
                if (completionAttempted.compareAndSet(false, true)) {
                    complete(result, nativeResponse)
                }
            }
        }
        if (!posted) {
            prepared.detachedFd?.let(::closeDetachedFileDescriptor)
            if (completionAttempted.compareAndSet(false, true)) {
                result.error(
                    "ERIKA_ERROR",
                    "Android presenter thread is unavailable",
                    mapOf("stage" to "presenter_invoke", "method" to method),
                )
            }
        }
    }

    private fun finishPreparedPlayerInvocation(
        host: AndroidPlayerHost,
        method: String,
        prepared: PreparedNativeArguments,
        response: NativeResponse,
    ) {
        val isCurrentHost = players[host.handle] === host && !host.isDestroyed
        if (isCurrentHost) {
            if (response.ok && method in RENDER_REQUEST_METHODS) {
                host.requestRender()
            }
            if (response.ok && method == "setPlaybackRate") {
                host.setPlaybackRate((prepared.arguments["rate"] as? Number)?.toFloat() ?: 1f)
                if (activeMediaPlayerId == host.handle) {
                    mediaSession.update(host.mediaState)
                }
            }
            if (response.ok && method == "close") {
                // Close is terminal for this native player handle. Any concurrently
                // requested Open will be rejected, so Closed must win locally as well.
                host.closeMediaState()
                if (activeMediaPlayerId == host.handle) {
                    mediaSession.update(host.mediaState)
                }
            }
            drainEvents(host)
            refreshFrameScheduling()
        }
    }

    private fun requiresAsyncContentPreparation(
        method: String,
        arguments: Map<String, Any?>,
    ): Boolean {
        if (method !in URI_METHODS) {
            return false
        }
        val uri = arguments["uri"] as? String ?: return false
        return uri.startsWith("content://", ignoreCase = true)
    }

    private fun invokePlayerAfterContentPreparation(
        host: AndroidPlayerHost,
        method: String,
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
        playbackIntentGeneration: Long?,
        contentGeneration: Long?,
    ) {
        val rawUri = arguments["uri"] as? String
            ?: throw IllegalArgumentException("uri is required")
        val cancellation = AndroidContentPreparationCancellation()
        val command = PendingContentCommand(
            host = host,
            method = method,
            authority = Uri.parse(rawUri).authority,
            result = result,
            cancellation = cancellation,
            playbackIntentGeneration = playbackIntentGeneration,
            contentGeneration = contentGeneration,
        )
        command.token = host.beginContentPreparation { reason ->
            cancelPendingContentCommand(command, reason)
        }

        val future = try {
            contentPreparationExecutor.submit {
                val prepared = runCatching {
                    prepareNativeArguments(method, arguments, cancellation)
                }
                val posted = mainHandler.post {
                    finishContentPreparation(command, prepared)
                }
                if (!posted) {
                    prepared.getOrNull()?.detachedFd?.let(::closeDetachedFileDescriptor)
                    cancellation.cancel()
                }
            }
        } catch (error: RejectedExecutionException) {
            host.finishContentPreparation(command.token)
            if (command.claimCompletion()) {
                cancellation.cancel()
                Log.e(TAG, "Android content preparation executor rejected $method", error)
                closeFailedContentOpen(command, "executor_unavailable")
                result.error(
                    "ERIKA_ERROR",
                    "Android content preparation executor is unavailable",
                    mapOf(
                        "stage" to "content_prepare",
                        "method" to method,
                        "reason" to "executor_unavailable",
                    ),
                )
            }
            return
        }
        cancellation.attachFuture(future)
    }

    private fun finishContentPreparation(
        command: PendingContentCommand,
        prepared: Result<PreparedNativeArguments>,
    ) {
        val current = command.host.finishContentPreparation(command.token)
        if (!current || !command.claimCompletion()) {
            prepared.getOrNull()?.detachedFd?.let(::closeDetachedFileDescriptor)
            return
        }
        val failure = prepared.exceptionOrNull()
        if (failure != null) {
            val reason = androidContentSourceFailureReason(failure)
            val cancelled = failure is AndroidContentPreparationCancelledException
            Log.e(
                TAG,
                androidContentSourceEvent(
                    stage = if (cancelled) "cancelled" else "failed",
                    authority = command.authority,
                    fields = linkedMapOf(
                        "mode" to "background_prepare",
                        "method" to command.method,
                        "playerId" to command.host.handle,
                        "reason" to reason,
                        "message" to (failure.message ?: failure.javaClass.simpleName),
                    ),
                ),
                failure,
            )
            if (!cancelled) {
                closeFailedContentOpen(command, reason)
            }
            command.result.error(
                if (cancelled) "ERIKA_CONTENT_CANCELLED" else "ERIKA_ERROR",
                failure.message ?: "Android content preparation failed",
                mapOf(
                    "stage" to "content_prepare",
                    "method" to command.method,
                    "reason" to reason,
                ),
            )
            return
        }

        val ready = checkNotNull(prepared.getOrNull())
        val playbackIntentGeneration = command.playbackIntentGeneration
        if (playbackIntentGeneration != null &&
            playbackIntentGeneration != command.host.currentPlaybackIntentGeneration
        ) {
            ready.detachedFd?.let(::closeDetachedFileDescriptor)
            closeFailedContentOpen(command, "superseded_playback_intent")
            command.result.error(
                "ERIKA_CONTENT_CANCELLED",
                "Android content command ${command.method} was superseded by newer playback intent",
                mapOf(
                    "stage" to "content_invoke",
                    "method" to command.method,
                    "reason" to "superseded_playback_intent",
                ),
            )
            return
        }

        try {
            invokePreparedPlayer(
                command.host,
                command.method,
                ready,
                command.result,
                command.playbackIntentGeneration,
                command.contentGeneration,
            )
        } catch (error: Throwable) {
            Log.e(TAG, "Async Erika ${command.method} invocation failed", error)
            command.result.error(
                "ERIKA_ERROR",
                error.message ?: "Erika Android method ${command.method} failed",
                mapOf("stage" to "content_invoke", "method" to command.method),
            )
        }
    }

    private fun cancelPendingContentCommand(command: PendingContentCommand, reason: String) {
        command.cancellation.cancel()
        if (!command.claimCompletion()) {
            return
        }
        Log.w(
            TAG,
            androidContentSourceEvent(
                stage = "cancelled",
                authority = command.authority,
                fields = linkedMapOf(
                    "mode" to "background_prepare",
                    "method" to command.method,
                    "playerId" to command.host.handle,
                    "reason" to reason,
                ),
            ),
        )
        runCatching {
            command.result.error(
                "ERIKA_CONTENT_CANCELLED",
                "Android content preparation for ${command.method} was cancelled: $reason",
                mapOf(
                    "stage" to "content_prepare",
                    "method" to command.method,
                    "reason" to reason,
                ),
            )
        }.onFailure { error ->
            // The Flutter messenger may already be detached. One failed result
            // delivery must not abort registry invalidation for other players.
            Log.w(
                TAG,
                "Failed to deliver cancelled Android content result for " +
                    "player ${command.host.handle}, method ${command.method}",
                error,
            )
        }
    }

    private fun closeFailedContentOpen(command: PendingContentCommand, reason: String) {
        closeFailedNativeOpen(command.host, command.method, command.contentGeneration, reason)
    }

    private fun closeFailedNativeOpen(
        host: AndroidPlayerHost,
        method: String,
        generation: Long?,
        reason: String,
    ) {
        if (!androidFailedContentOpenShouldClose(
                method = method,
                hostDestroyed = host.isDestroyed,
                failedGeneration = generation,
                currentGeneration = host.currentContentGeneration,
            )
        ) {
            return
        }
        Log.w(
            TAG,
            "Closing player ${host.handle} after content Open preparation failed: $reason",
        )
        host.cancelPlaybackIntent(forceNewGeneration = true)
        abandonAudioFocusIfIdle()
        postBackgroundCommand(host, "failed content open", "close")
    }

    private fun playWithAudioFocus(host: AndroidPlayerHost, result: MethodChannel.Result) {
        val intentGeneration = host.requestPlayback()
        refreshFrameScheduling()
        if (!host.mediaState.canPlay(isActivityActive)) {
            host.cancelPlaybackIntentLocally()
            result.success(null)
            return
        }
        val focusGrant = try {
            audioFocus.request()
        } catch (error: Throwable) {
            host.cancelPlaybackIntentLocally()
            abandonAudioFocusIfIdle()
            refreshFrameScheduling()
            throw error
        }
        when (focusGrant) {
            AudioFocusGrant.GRANTED -> {
                pendingPlayResults
                    .getOrPut(PendingPlayKey(host, intentGeneration), ::mutableListOf)
                    .add(result)
                startPendingPlayback(host, "method channel")
            }
            AudioFocusGrant.DELAYED -> result.success(null)
            AudioFocusGrant.DENIED -> {
                host.cancelPlaybackIntentLocally()
                abandonAudioFocusIfIdle()
                refreshFrameScheduling()
                result.error("ERIKA_AUDIO_FOCUS", "Android audio focus request was denied", null)
            }
        }
    }

    private fun completePendingPlayResults(
        host: AndroidPlayerHost,
        intentGeneration: Long,
        response: NativeResponse,
    ) {
        pendingPlayResults.remove(PendingPlayKey(host, intentGeneration)).orEmpty().forEach {
            runCatching { complete(it, response) }
                .onFailure { error -> Log.w(TAG, "Unable to deliver Android play result", error) }
        }
    }

    private fun failPendingPlayResults(
        host: AndroidPlayerHost,
        intentGeneration: Long,
        error: Throwable,
    ) {
        pendingPlayResults.remove(PendingPlayKey(host, intentGeneration)).orEmpty().forEach {
            runCatching {
                it.error(
                    "ERIKA_ERROR",
                    error.message ?: "Erika Android play failed",
                    mapOf("stage" to "presenter_invoke", "method" to "play"),
                )
            }.onFailure { deliveryError ->
                Log.w(TAG, "Unable to deliver failed Android play result", deliveryError)
            }
        }
    }

    private fun failAllPendingPlayResults(host: AndroidPlayerHost, error: Throwable) {
        pendingPlayResults.keys
            .filter { key -> key.host === host }
            .map(PendingPlayKey::intentGeneration)
            .forEach { generation -> failPendingPlayResults(host, generation, error) }
    }

    private fun pauseInvalidatedAsyncPlay(host: AndroidPlayerHost) {
        postBackgroundCommand(host, "invalidated async", "pause")
    }

    private fun activateMediaPlayer(host: AndroidPlayerHost) {
        activeMediaPlayerId = host.handle
        ErikaMediaCommandReceiver.activate(this)
        mediaSession.update(host.mediaState.copy(playbackState = PLAYING_STATE))
    }

    private fun rollbackAcceptedAsyncPlay(
        host: AndroidPlayerHost,
        source: String,
        cause: Throwable,
    ) {
        Log.e(TAG, "$source play completion failed; rolling native playback back", cause)
        host.cancelPlaybackIntent(forceNewGeneration = true)
        host.reconcileNativePlaybackStopped()
        if (activeMediaPlayerId == host.handle) {
            activeMediaPlayerId = null
            runCatching { ErikaMediaCommandReceiver.deactivate(this) }
                .onFailure { error -> Log.e(TAG, "Unable to deactivate media commands", error) }
            runCatching { mediaSession.clear(host.handle) }
                .onFailure { error -> Log.e(TAG, "Unable to clear failed media session", error) }
        }
        abandonAudioFocusIfIdle()
        pauseInvalidatedAsyncPlay(host)
    }

    private fun postMainSafely(
        source: String,
        onFailure: (Throwable) -> Unit = {},
        block: () -> Unit,
    ): Boolean {
        val posted = mainHandler.post {
            try {
                block()
            } catch (error: Throwable) {
                Log.e(TAG, "Android main callback failed: $source", error)
                runCatching { onFailure(error) }
                    .onFailure { recoveryError ->
                        Log.e(TAG, "Android main callback recovery failed: $source", recoveryError)
                    }
            }
        }
        if (!posted) {
            val error = IllegalStateException("Android main callback was rejected: $source")
            Log.w(TAG, error.message, error)
            runCatching { onFailure(error) }
                .onFailure { recoveryError ->
                    Log.e(TAG, "Android rejected callback recovery failed: $source", recoveryError)
                }
        }
        return posted
    }

    private fun postBackgroundCommand(
        host: AndroidPlayerHost,
        source: String,
        method: String,
        arguments: Map<String, Any?> = emptyMap(),
    ) {
        val playbackIntentGeneration = method
            .takeIf { it == "play" || it in PLAYBACK_INTENT_CANCEL_METHODS }
            ?.let { host.currentPlaybackIntentGeneration }
        val contentGeneration = method
            .takeIf(CONTENT_PREPARATION_INVALIDATION_METHODS::contains)
            ?.let { host.currentContentGeneration }
        val posted = presenterThread.post {
            if (host.isDestroyed) {
                return@post
            }
            playbackIntentGeneration?.let(host::markPlaybackIntentExecuted)
            val response = runCatching { host.invoke(method, arguments) }
            if (androidContentCommandEstablishedBoundary(
                    method = method,
                    responseDecoded = response.isSuccess,
                    responseOk = response.getOrNull()?.ok == true,
                )
            ) {
                contentGeneration?.let(host::markContentGenerationExecuted)
            }
            val events = pollEventsOnPresenterThread(host)
            postMainSafely("$source $method completion") main@{
                if (players[host.handle] !== host || host.isDestroyed) {
                    return@main
                }
                processPolledEvents(events)
                response
                    .onSuccess { nativeResponse ->
                        reportBackgroundCommand(host, source, method, nativeResponse)
                    }
                    .onFailure { error ->
                        Log.e(TAG, "$source $method threw for player ${host.handle}", error)
                    }
                drainEvents(host)
                refreshFrameScheduling()
            }
        }
        if (!posted) {
            Log.w(TAG, "Unable to post $source $method for player ${host.handle}")
        }
    }

    private fun attachToActivity(binding: ActivityPluginBinding) {
        detachFromActivity()
        activity = binding.activity
        val lifecycle = try {
            FlutterLifecycleAdapter.getActivityLifecycle(binding)
        } catch (error: Throwable) {
            Log.e(
                TAG,
                "activityLifecycleAttachFailed activity=${binding.activity.javaClass.name} active=false",
                error,
            )
            setActivityActive(false)
            return
        }
        activityLifecycle = lifecycle
        lifecycle.addObserver(this)
        val active = androidActivityIsActive(lifecycle.currentState)
        Log.i(
            TAG,
            "activityLifecycleAttached activity=${binding.activity.javaClass.name} " +
                "activityIsLifecycleOwner=${binding.activity is LifecycleOwner} " +
                "state=${lifecycle.currentState} active=$active",
        )
        setActivityActive(active)
    }

    private fun detachFromActivity() {
        activityLifecycle?.let { lifecycle ->
            lifecycle.removeObserver(this)
            Log.i(TAG, "activityLifecycleDetached state=${lifecycle.currentState} active=false")
        }
        activityLifecycle = null
        activity = null
        setActivityActive(false)
    }

    private fun setActivityActive(active: Boolean) {
        if (activityActive == active) {
            refreshFrameScheduling()
            return
        }
        activityActive = active
        if (active) {
            resumeFromActivityStop()
        } else {
            suspendForActivityStop()
        }
    }

    private fun suspendForActivityStop() {
        cancelFrameCallback()
        val hostsToPause = players.values.toList().mapNotNull { host ->
            if (host.mediaState.allowBackgroundPlayback) {
                return@mapNotNull null
            }
            if (host.cancelPlaybackIntent()) {
                host
            } else {
                host.markPlaybackIntentExecuted(host.currentPlaybackIntentGeneration)
                null
            }
        }
        if (players.values.none { host ->
                host.mediaState.allowBackgroundPlayback &&
                    host.playbackPhase != AndroidPlaybackPhase.PAUSED
            }
        ) {
            audioFocus.abandon()
        }
        hostsToPause.forEach { host ->
            postBackgroundCommand(host, "lifecycle", "pause")
        }
        videoViews.values.toList().forEach { view ->
            runCatching(view::suspendSurfaceAsync)
                .onFailure { error -> Log.e(TAG, "Lifecycle surface detach threw", error) }
        }
        players.values.toList().forEach(::drainEvents)
        refreshFrameScheduling()
    }

    private fun resumeFromActivityStop() {
        videoViews.values.toList().forEach { view ->
            runCatching(view::resumeSurface)
                .onFailure { error -> Log.e(TAG, "Lifecycle surface attach threw", error) }
        }
        resumePendingPlayback()
        refreshFrameScheduling()
    }

    private fun resumePendingPlayback() {
        if (!isActivityActive) {
            return
        }
        val pendingHosts = players.values.toList()
            .filter { it.playbackPhase == AndroidPlaybackPhase.PENDING }
        if (pendingHosts.isEmpty()) {
            return
        }
        val focusGrant = try {
            audioFocus.request()
        } catch (error: Throwable) {
            pendingHosts.forEach { host -> host.cancelPlaybackIntentLocally() }
            abandonAudioFocusIfIdle()
            Log.e(TAG, "Android audio focus request threw while resuming playback", error)
            return
        }
        when (focusGrant) {
            AudioFocusGrant.GRANTED -> {
                pendingHosts.forEach { host ->
                    startPendingPlayback(host, "lifecycle")
                }
            }
            AudioFocusGrant.DELAYED -> Unit
            AudioFocusGrant.DENIED -> {
                pendingHosts.forEach { host -> host.cancelPlaybackIntentLocally() }
                abandonAudioFocusIfIdle()
                Log.w(TAG, "Android audio focus denied while resuming Erika playback")
            }
        }
    }

    private fun startPendingPlayback(host: AndroidPlayerHost, source: String) {
        if (!host.mediaState.canPlay(isActivityActive) ||
            !audioFocus.focusGranted ||
            host.playbackPhase != AndroidPlaybackPhase.PENDING
        ) {
            return
        }
        val invocationGeneration = host.tryBeginPlayInvocation() ?: return
        val posted = presenterThread.post {
            host.markPlaybackIntentExecuted(invocationGeneration)
            val response = runCatching { host.invoke("play", emptyMap()) }
            val events = pollEventsOnPresenterThread(host)
            var isCurrentIntent: Boolean? = null
            postMainSafely(
                source = "$source play completion",
                onFailure = { error ->
                    // Remove the pending result first so even a rollback failure cannot strand
                    // the MethodChannel Future or cause a second delivery attempt.
                    failPendingPlayResults(host, invocationGeneration, error)
                    val isCurrentHost = players[host.handle] === host && !host.isDestroyed
                    val ownsCurrentIntent = isCurrentIntent
                        ?: host.finishPlayInvocation(invocationGeneration)
                    if (isCurrentHost && ownsCurrentIntent) {
                        if (androidAsyncPlayCallbackNeedsRollback(
                                nativePlayAccepted = response.getOrNull()?.ok == true,
                                isCurrentHost = isCurrentHost,
                                ownsCurrentIntent = ownsCurrentIntent,
                            )
                        ) {
                            rollbackAcceptedAsyncPlay(host, source, error)
                        } else {
                            host.reconcileNativePlaybackStopped()
                            abandonAudioFocusIfIdle()
                        }
                    }
                    if (isCurrentHost) {
                        runCatching { startPendingPlayback(host, "queued play intent") }
                            .onFailure { cleanupError ->
                                Log.e(TAG, "Unable to resume queued play after callback failure", cleanupError)
                            }
                        runCatching { drainEvents(host) }
                            .onFailure { cleanupError ->
                                Log.e(TAG, "Unable to drain events after callback failure", cleanupError)
                            }
                        runCatching(::refreshFrameScheduling)
                            .onFailure { cleanupError ->
                                Log.e(TAG, "Unable to refresh frames after callback failure", cleanupError)
                            }
                    }
                },
            ) {
                val isCurrentHost = players[host.handle] === host && !host.isDestroyed
                val ownsCurrentIntent = host.finishPlayInvocation(invocationGeneration)
                    .also { isCurrentIntent = it }
                if (isCurrentHost) {
                    processPolledEvents(events)
                }
                val nativeResponse = response.getOrElse { error ->
                    throw IllegalStateException(
                        error.message ?: "Erika Android play failed",
                        error,
                    )
                }
                if (isCurrentHost) {
                    when {
                        !nativeResponse.ok && ownsCurrentIntent -> {
                            host.reconcileNativePlaybackStopped()
                            abandonAudioFocusIfIdle()
                        }
                        !nativeResponse.ok -> Unit
                        !ownsCurrentIntent && events.playbackIntentState == PLAYING_STATE -> {
                            pauseInvalidatedAsyncPlay(host)
                        }
                        !ownsCurrentIntent -> Unit
                        host.playbackPhase == AndroidPlaybackPhase.PLAYING -> {
                            activateMediaPlayer(host)
                        }
                        androidAsyncPlayCanStart(
                            phase = host.playbackPhase,
                            canPlayInCurrentActivityState =
                                host.mediaState.canPlay(isActivityActive),
                            audioFocusGranted = audioFocus.focusGranted,
                        ) && host.playbackStarted() -> {
                            activateMediaPlayer(host)
                        }
                        else -> pauseInvalidatedAsyncPlay(host)
                    }
                    reportBackgroundCommand(host, source, "play", nativeResponse)
                }
                if (isCurrentHost) {
                    // A play requested while an older generation was in flight must be
                    // queued after its already-submitted pause/stop command.
                    startPendingPlayback(host, "queued play intent")
                    drainEvents(host)
                    refreshFrameScheduling()
                }
                // Delivery is last; any callback exception above is converted to one error.
                completePendingPlayResults(host, invocationGeneration, nativeResponse)
            }
        }
        if (!posted) {
            val isCurrentIntent = host.finishPlayInvocation(invocationGeneration)
            if (isCurrentIntent) {
                host.cancelPlaybackIntentLocally()
                abandonAudioFocusIfIdle()
            }
            val error = IllegalStateException("Android presenter thread is unavailable")
            failPendingPlayResults(host, invocationGeneration, error)
            Log.w(TAG, "Unable to post $source play for player ${host.handle}", error)
        }
    }

    private fun prepareNativeArguments(
        method: String,
        arguments: Map<String, Any?>,
        cancellation: AndroidContentPreparationCancellation? = null,
    ): PreparedNativeArguments {
        val nativeArguments = arguments.toMutableMap()
        nativeArguments.remove("playerId")
        if (method == "open") {
            nativeArguments.remove("metadata")
        }
        if (method !in URI_METHODS) {
            return PreparedNativeArguments(nativeArguments, null)
        }
        val rawUri = nativeArguments["uri"] as? String
            ?: return PreparedNativeArguments(nativeArguments, null)
        if (!rawUri.startsWith("content://", ignoreCase = true)) {
            return PreparedNativeArguments(nativeArguments, null)
        }
        val source = detachContentSource(
            Uri.parse(rawUri),
            cancellation ?: AndroidContentPreparationCancellation(),
        )
        nativeArguments["uri"] = source.uri
        return PreparedNativeArguments(nativeArguments, source.fd)
    }

    private fun detachContentSource(
        uri: Uri,
        cancellation: AndroidContentPreparationCancellation,
    ): DetachedContentSource {
        cancellation.throwIfCancelled()
        val resolver = applicationContext.contentResolver
        val asset = resolver.openAssetFileDescriptor(uri, "r")
        if (asset != null) {
            return asset.use { openedAsset ->
                cancellation.throwIfCancelled()
                val offset = max(0L, openedAsset.startOffset)
                val declaredLength = openedAsset.declaredLength.takeIf { it >= 0L }
                val reportedLength = openedAsset.length.takeIf { it > 0L }
                val probe = probeContentDescriptor(openedAsset.parcelFileDescriptor.fileDescriptor)
                when (probe.transport) {
                    AndroidContentTransport.OWNED_DESCRIPTOR -> {
                        val length = resolveSeekableContentLength(
                            uri = uri,
                            offset = offset,
                            declaredLength = declaredLength,
                            reportedLength = reportedLength,
                            endOffset = probe.endOffset,
                        )
                        Log.i(
                            TAG,
                            androidContentSourceEvent(
                                stage = "zero_copy",
                                authority = uri.authority,
                                fields = linkedMapOf(
                                    "offset" to offset,
                                    "length" to length,
                                ),
                            ),
                        )
                        detachAssetFileDescriptor(openedAsset, offset, length)
                    }
                    AndroidContentTransport.CACHE_SPOOL -> spoolContentSource(
                        uri = uri,
                        sourceOffset = offset,
                        expectedLength = declaredLength,
                        fallbackReason = probe.fallbackReason,
                        cancellation = cancellation,
                        openInput = openedAsset::createInputStream,
                    )
                }
            }
        }
        val descriptor = resolver.openFileDescriptor(uri, "r")
            ?: throw FileNotFoundException("Unable to open Android content URI: $uri")
        return descriptor.use { openedDescriptor ->
            cancellation.throwIfCancelled()
            val reportedLength = openedDescriptor.statSize.takeIf { it > 0L }
            val probe = probeContentDescriptor(openedDescriptor.fileDescriptor)
            when (probe.transport) {
                AndroidContentTransport.OWNED_DESCRIPTOR -> {
                    val length = resolveSeekableContentLength(
                        uri = uri,
                        offset = 0L,
                        declaredLength = null,
                        reportedLength = reportedLength,
                        endOffset = probe.endOffset,
                    )
                    Log.i(
                        TAG,
                        androidContentSourceEvent(
                            stage = "zero_copy",
                            authority = uri.authority,
                            fields = linkedMapOf(
                                "offset" to 0L,
                                "length" to length,
                            ),
                        ),
                    )
                    val fd = openedDescriptor.detachFd()
                    detachedContentSource(fd, 0L, length)
                }
                AndroidContentTransport.CACHE_SPOOL -> spoolContentSource(
                    uri = uri,
                    sourceOffset = 0L,
                    expectedLength = null,
                    fallbackReason = probe.fallbackReason,
                    cancellation = cancellation,
                    openInput = { ParcelFileDescriptor.AutoCloseInputStream(openedDescriptor) },
                )
            }
        }
    }

    private fun detachAssetFileDescriptor(
        asset: AssetFileDescriptor,
        offset: Long,
        length: Long?,
    ): DetachedContentSource {
        val fd = asset.parcelFileDescriptor.detachFd()
        return detachedContentSource(fd, offset, length)
    }

    private fun probeContentDescriptor(fileDescriptor: FileDescriptor): ContentDescriptorProbe {
        val stat = try {
            Os.fstat(fileDescriptor)
        } catch (error: ErrnoException) {
            return ContentDescriptorProbe(
                transport = AndroidContentTransport.CACHE_SPOOL,
                endOffset = null,
                fallbackReason = "fstat_errno_${error.errno}",
            )
        }
        val kind = when {
            OsConstants.S_ISREG(stat.st_mode) -> AndroidContentDescriptorKind.REGULAR_FILE
            OsConstants.S_ISFIFO(stat.st_mode) -> AndroidContentDescriptorKind.FIFO
            OsConstants.S_ISSOCK(stat.st_mode) -> AndroidContentDescriptorKind.SOCKET
            OsConstants.S_ISCHR(stat.st_mode) -> AndroidContentDescriptorKind.CHARACTER_DEVICE
            OsConstants.S_ISBLK(stat.st_mode) -> AndroidContentDescriptorKind.BLOCK_DEVICE
            else -> AndroidContentDescriptorKind.OTHER
        }
        val statSize = stat.st_size.takeIf { it >= 0L }
        val transport = androidContentTransport(kind, statSize)
        return ContentDescriptorProbe(
            transport = transport,
            endOffset = statSize.takeIf {
                transport == AndroidContentTransport.OWNED_DESCRIPTOR
            },
            fallbackReason = if (transport == AndroidContentTransport.CACHE_SPOOL) {
                androidContentFallbackReason(kind)
            } else {
                null
            },
        )
    }

    private fun resolveSeekableContentLength(
        uri: Uri,
        offset: Long,
        declaredLength: Long?,
        reportedLength: Long?,
        endOffset: Long?,
    ): Long? {
        if (endOffset != null && endOffset < offset) {
            logEmptyOrInvalidDescriptor(uri, offset, "offset_beyond_descriptor")
            throw EOFException(
                "Android content descriptor offset $offset exceeds its end $endOffset",
            )
        }
        if (declaredLength != null && endOffset != null) {
            if (declaredLength > endOffset - offset) {
                logEmptyOrInvalidDescriptor(uri, offset, "declared_slice_truncated")
                throw EOFException(
                    "Android content descriptor slice is truncated: offset=$offset, " +
                        "length=$declaredLength, end=$endOffset",
                )
            }
        }
        val length = declaredLength
            ?: endOffset?.minus(offset)
            ?: reportedLength
        if (length == 0L) {
            logEmptyOrInvalidDescriptor(uri, offset, "empty_descriptor")
            throw EOFException("Android content descriptor is empty")
        }
        if (length == null) {
            Log.w(
                TAG,
                androidContentSourceEvent(
                    stage = "length_unknown",
                    authority = uri.authority,
                    fields = linkedMapOf(
                        "mode" to "zero_copy",
                        "reason" to "provider_length_unavailable",
                        "offset" to offset,
                    ),
                ),
            )
        }
        return length
    }

    private fun logEmptyOrInvalidDescriptor(uri: Uri, offset: Long, reason: String) {
        Log.e(
            TAG,
            androidContentSourceEvent(
                stage = "failed",
                authority = uri.authority,
                fields = linkedMapOf(
                    "mode" to "zero_copy",
                    "reason" to reason,
                    "offset" to offset,
                ),
            ),
        )
    }

    private fun spoolContentSource(
        uri: Uri,
        sourceOffset: Long,
        expectedLength: Long?,
        fallbackReason: String?,
        cancellation: AndroidContentPreparationCancellation,
        openInput: () -> InputStream,
    ): DetachedContentSource {
        cancellation.throwIfCancelled()
        awaitContentSpoolStartupScavenge(cancellation)
        val startedAt = SystemClock.elapsedRealtime()
        val policy = AndroidContentSpoolPolicy()
        Log.w(
            TAG,
            androidContentSourceEvent(
                stage = "fallback",
                authority = uri.authority,
                fields = linkedMapOf(
                    "mode" to "cache_spool",
                    "reason" to (fallbackReason ?: "non_seekable_descriptor"),
                    "sourceOffset" to sourceOffset,
                    "declaredLength" to expectedLength,
                    "execution" to "background",
                    "maxBytes" to policy.maxBytes,
                    "minFreeBytes" to policy.minFreeBytes,
                ),
            ),
        )
        var cacheFile: File? = null
        var bytesWritten: Long? = null
        try {
            val cacheDirectory = File(applicationContext.cacheDir, ANDROID_CONTENT_SPOOL_DIRECTORY)
            if (!cacheDirectory.isDirectory &&
                !cacheDirectory.mkdirs() &&
                !cacheDirectory.isDirectory
            ) {
                throw IOException("Unable to create Erika Android content spool directory")
            }
            cancellation.throwIfCancelled()
            val outputFile = File.createTempFile(
                ANDROID_CONTENT_SPOOL_PREFIX,
                ANDROID_CONTENT_SPOOL_SUFFIX,
                cacheDirectory,
            )
            cacheFile = outputFile
            cancellation.trackTemporaryFile(outputFile)
            val input = openInput()
            cancellation.register(input)
            try {
                input.use {
                    FileOutputStream(outputFile).use { output ->
                        cancellation.register(output)
                        try {
                            bytesWritten = AndroidContentSpooler.copy(
                                input = input,
                                output = output,
                                expectedLength = expectedLength,
                                policy = policy,
                                availableBytes = { cacheDirectory.usableSpace },
                                cancelled = { cancellation.isCancelled },
                                onProgress = { bytes -> bytesWritten = bytes },
                            )
                            cancellation.throwIfCancelled()
                            output.fd.sync()
                        } finally {
                            cancellation.unregister(output)
                        }
                    }
                }
            } finally {
                cancellation.unregister(input)
            }
            cancellation.throwIfCancelled()
            val length = checkNotNull(bytesWritten)
            val source = detachCachedContentSource(outputFile, length)
            cancellation.releaseTemporaryFile(outputFile)
            try {
                Log.i(
                    TAG,
                    androidContentSourceEvent(
                        stage = "spool_complete",
                        authority = uri.authority,
                        fields = linkedMapOf(
                            "bytes" to length,
                            "elapsedMs" to SystemClock.elapsedRealtime() - startedAt,
                            "cachePathRetained" to false,
                        ),
                    ),
                )
            } catch (error: Throwable) {
                closeDetachedFileDescriptor(source.fd)
                throw error
            }
            return source
        } catch (error: Throwable) {
            val partialFile = cacheFile
            val deleted = partialFile == null || deleteContentSpoolFile(partialFile)
            partialFile?.let(cancellation::releaseTemporaryFile)
            Log.e(
                TAG,
                androidContentSourceEvent(
                    stage = "failed",
                    authority = uri.authority,
                    fields = linkedMapOf(
                        "mode" to "cache_spool",
                        "reason" to androidContentSourceFailureReason(error),
                        "message" to (error.message ?: error.javaClass.simpleName),
                        "bytes" to bytesWritten,
                        "partialCacheDeleted" to deleted,
                        "elapsedMs" to SystemClock.elapsedRealtime() - startedAt,
                    ),
                ),
                error,
            )
            throw error
        }
    }

    private fun detachCachedContentSource(cacheFile: File, length: Long): DetachedContentSource {
        val descriptor = ParcelFileDescriptor.open(cacheFile, ParcelFileDescriptor.MODE_READ_ONLY)
        val fd = try {
            descriptor.detachFd()
        } catch (error: Throwable) {
            descriptor.close()
            throw error
        }
        val unlinked = try {
            cacheFile.delete()
        } catch (error: Throwable) {
            closeDetachedFileDescriptor(fd)
            throw error
        }
        if (!unlinked) {
            closeDetachedFileDescriptor(fd)
            throw IOException(
                "Unable to unlink Erika Android content spool file ${cacheFile.name}",
            )
        }
        // The path is now gone, but the detached descriptor keeps the inode alive until Rust
        // drops its OwnedFileDescriptorSource. No cache path can leak across player lifetimes.
        return detachedContentSource(fd, 0L, length)
    }

    private fun detachedContentSource(
        fd: Int,
        offset: Long,
        length: Long?,
    ): DetachedContentSource = try {
        DetachedContentSource(fd, fdUri(fd, offset, length))
    } catch (error: Throwable) {
        closeDetachedFileDescriptor(fd)
        throw error
    }

    private fun fdUri(fd: Int, offset: Long, length: Long?): String = buildString {
        append("fd://")
        append(fd)
        append("?offset=")
        append(max(0L, offset))
        if (length != null) {
            append("&length=")
            append(length)
        }
    }

    private fun closeDetachedFileDescriptor(fd: Int) {
        runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            .onFailure { error -> Log.w(TAG, "Unable to close detached content fd $fd", error) }
    }

    private fun handleAudioFocusLoss(mayResume: Boolean) {
        players.values.toList().forEach { host ->
            if (host.playbackPhase == AndroidPlaybackPhase.PAUSED) {
                return@forEach
            }
            val shouldPause = host.handleFocusLoss(mayResume)
            if (shouldPause) {
                postBackgroundCommand(host, "audio focus", "pause")
            } else {
                // Delayed focus can be cancelled before native Play is ever
                // invoked, so there is no presenter command to acknowledge it.
                host.markPlaybackIntentExecuted(host.currentPlaybackIntentGeneration)
            }
            drainEvents(host)
        }
        if (!mayResume) {
            abandonAudioFocusIfIdle()
        }
        refreshFrameScheduling()
    }

    private fun handleAudioFocusGain() {
        if (!audioFocus.focusGranted) {
            return
        }
        players.values.toList()
            .filter {
                it.playbackPhase == AndroidPlaybackPhase.PENDING &&
                    (isActivityActive || it.mediaState.allowBackgroundPlayback)
            }
            .forEach { host ->
                // The transient-loss Pause may still be queued on the presenter. Give the
                // resumed Play a fresh generation so that Pause cannot roll host state back.
                host.renewPendingPlaybackIntent()
                startPendingPlayback(host, "audio focus")
            }
        refreshFrameScheduling()
    }

    private fun abandonAudioFocusIfIdle() {
        if (players.values.none { it.playbackPhase != AndroidPlaybackPhase.PAUSED }) {
            audioFocus.abandon()
        }
    }

    private fun reportBackgroundCommand(
        host: AndroidPlayerHost,
        source: String,
        method: String,
        response: NativeResponse,
    ) {
        if (!response.ok) {
            Log.e(
                TAG,
                "$source $method failed for player ${host.handle}: " +
                    "status=${response.status} ${response.error.orEmpty()}",
            )
        }
    }

    private fun refreshFrameScheduling() {
        videoViews.values.forEach { view ->
            val phase = view.boundPlayerHost?.playbackPhase
            view.setPlaybackKeepsScreenOn(
                isActivityActive && phase != null && phase != AndroidPlaybackPhase.PAUSED,
            )
        }
        val needsFrame = isActivityActive && players.values.any(AndroidPlayerHost::shouldTick)
        if (!needsFrame) {
            cancelFrameCallback()
            return
        }
        if (!frameScheduled) {
            frameScheduled = true
            choreographer.postFrameCallback(frameCallback)
        }
    }

    private fun enqueueRenderTick(targets: List<AndroidRenderTarget>, timeSeconds: Double) {
        val request = AndroidRenderRequest(
            timeSeconds = timeSeconds,
            targets = targets,
            generation = renderGeneration.get(),
        )
        if (renderRequests.submit(request)) {
            postRenderDrain()
        }
    }

    private fun postRenderDrain() {
        if (!presenterThread.post(::drainRenderRequests)) {
            renderRequests.abortDrain()
        }
    }

    private fun drainRenderRequests() {
        val request = renderRequests.takeLatest()
        if (request != null && request.generation == renderGeneration.get()) {
            if (renderThreadReported.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "presenterRenderThread tid=${Process.myTid()} " +
                        "mainThread=${Looper.myLooper() === Looper.getMainLooper()}",
                )
            }
            val outcomes = request.targets.mapNotNull { target ->
                val host = target.host
                if (host.isDestroyed) {
                    null
                } else {
                    val contentGeneration = host.latestExecutedContentGeneration
                    val result = runCatching { host.renderTick(request.timeSeconds) }
                    AndroidRenderOutcome(
                        host,
                        target.renderRequestGeneration,
                        contentGeneration,
                        result.getOrNull(),
                        result.exceptionOrNull(),
                    )
                }
            }
            postMainSafely("video render completion") main@{
                if (request.generation != renderGeneration.get()) {
                    return@main
                }
                outcomes.forEach { outcome ->
                    val host = outcome.host
                    if (players[host.handle] !== host || host.isDestroyed) {
                        return@forEach
                    }
                    try {
                        val response = outcome.response
                        if (response != null) {
                            reportRenderResponse(host, outcome.contentGeneration, response)
                        } else {
                            reportRenderException(
                                host,
                                outcome.contentGeneration,
                                outcome.error
                                    ?: IllegalStateException("renderTick failed without an error"),
                            )
                        }
                    } finally {
                        host.markRenderAttempted(outcome.renderRequestGeneration)
                    }
                }
            }
        }
        if (renderRequests.finishDrain()) {
            // Requeue at the tail so surface, command, event, and destroy work
            // cannot be starved by a continuously overloaded render loop.
            postRenderDrain()
        }
    }

    private fun performBackgroundPlaybackTick(@Suppress("UNUSED_PARAMETER") timeSeconds: Double) {
        if (isActivityActive) {
            return
        }
        val tickingPlayers = players.values.toList()
            .filter {
                it.mediaState.allowBackgroundPlayback &&
                    it.playbackPhase == AndroidPlaybackPhase.PLAYING
            }
            .map { host -> AndroidRenderTarget(host, 0L) }
        if (tickingPlayers.isEmpty() || !backgroundTickQueued.compareAndSet(false, true)) {
            return
        }
        val posted = presenterThread.post {
            val outcomes = tickingPlayers.mapNotNull { target ->
                val host = target.host
                if (host.isDestroyed) {
                    null
                } else {
                    val contentGeneration = host.latestExecutedContentGeneration
                    val result = runCatching { host.audioOnlyTick() }
                    AndroidRenderOutcome(
                        host,
                        0L,
                        contentGeneration,
                        result.getOrNull(),
                        result.exceptionOrNull(),
                    )
                }
            }
            backgroundTickQueued.set(false)
            postMainSafely("background audio render completion") {
                outcomes.forEach { outcome ->
                    val host = outcome.host
                    if (players[host.handle] !== host || host.isDestroyed) {
                        return@forEach
                    }
                    outcome.response?.let {
                        reportRenderResponse(host, outcome.contentGeneration, it)
                    }
                        ?: reportRenderException(
                            host,
                            outcome.contentGeneration,
                            outcome.error
                                ?: IllegalStateException("audioOnlyTick failed without an error"),
                        )
                }
            }
        }
        if (!posted) {
            backgroundTickQueued.set(false)
        }
    }

    private fun cancelFrameCallback() {
        renderGeneration.incrementAndGet()
        renderRequests.cancelPending()
        if (frameScheduled) {
            choreographer.removeFrameCallback(frameCallback)
            frameScheduled = false
        }
    }

    private fun reportRenderResponse(
        host: AndroidPlayerHost,
        contentGeneration: Long,
        response: NativeResponse,
    ) {
        if (response.ok) {
            if (host.lastRenderErrorContentGeneration == contentGeneration) {
                host.lastRenderError = null
                host.lastRenderErrorContentGeneration = null
            }
            return
        }
        val signature = "${response.status}:${response.error.orEmpty()}"
        if (host.lastRenderError != signature ||
            host.lastRenderErrorContentGeneration != contentGeneration
        ) {
            host.lastRenderError = signature
            host.lastRenderErrorContentGeneration = contentGeneration
            Log.e(TAG, "renderTick failed for player ${host.handle}: $signature")
            enqueueHostError(
                host,
                "renderTick",
                response.status,
                response.error ?: "renderTick failed",
                contentGeneration = contentGeneration,
            )
        }
    }

    private fun reportRenderException(
        host: AndroidPlayerHost,
        contentGeneration: Long,
        error: Throwable,
    ) {
        val signature = "exception:${error.message.orEmpty()}"
        if (host.lastRenderError != signature ||
            host.lastRenderErrorContentGeneration != contentGeneration
        ) {
            host.lastRenderError = signature
            host.lastRenderErrorContentGeneration = contentGeneration
            Log.e(TAG, "renderTick threw for player ${host.handle}", error)
            enqueueHostError(
                host,
                "renderTick",
                -1,
                error.message ?: "renderTick threw",
                contentGeneration = contentGeneration,
            )
        }
    }

    private fun enqueueHostError(
        host: AndroidPlayerHost,
        stage: String,
        status: Int,
        error: String,
        details: Map<String, Any?> = emptyMap(),
        contentGeneration: Long?,
    ) {
        val event = linkedMapOf<String, Any?>(
            "playerId" to host.handle,
            "kind" to ERROR_EVENT_KIND,
            "state" to ERROR_STATE,
            "status" to status,
            "error" to error,
            "message" to "Android host failure during $stage",
            "hostStage" to stage,
        )
        event.putAll(details)
        enqueuePendingEvent(
            host,
            AndroidPendingEvent.Success(event, contentGeneration),
        )
        flushPendingEvents(host)
    }

    private fun enqueuePendingEvent(host: AndroidPlayerHost, event: AndroidPendingEvent) {
        val overflow = host.enqueuePendingEvent(event) ?: return
        if (overflow.droppedTotal == 1L ||
            overflow.droppedTotal % EVENT_OVERFLOW_LOG_INTERVAL == 0L
        ) {
            val droppedType = when (val dropped = overflow.dropped) {
                is AndroidPendingEvent.Success ->
                    "success(kind=${(dropped.value["kind"] as? Number)?.toInt()})"
                is AndroidPendingEvent.Error -> "error(code=${dropped.code})"
            }
            Log.w(
                TAG,
                "pendingEventQueueOverflow playerId=${host.handle} " +
                    "policy=drop_oldest capacity=${overflow.capacity} " +
                    "droppedTotal=${overflow.droppedTotal} dropped=$droppedType",
            )
        }
    }

    private fun flushPendingEvents(host: AndroidPlayerHost) {
        val sink = eventSink ?: return
        // `prepareForOpen` prunes eagerly; repeat here as a defensive boundary
        // for events retained after a sink exception.
        host.discardStalePendingEvents()
        while (eventSink === sink) {
            val event = host.firstPendingEvent() ?: return
            try {
                when (event) {
                    is AndroidPendingEvent.Success -> sink.success(event.value)
                    is AndroidPendingEvent.Error ->
                        sink.error(event.code, event.message, event.details)
                }
            } catch (error: Throwable) {
                Log.e(
                    TAG,
                    "EventChannel delivery failed for player ${host.handle}; retaining event",
                    error,
                )
                return
            }
            host.removeFirstPendingEvent()
        }
    }

    private fun drainEvents(host: AndroidPlayerHost) {
        flushPendingEvents(host)
        host.eventPollBackoff.reset()
        eventPollIdleRounds = 0
        requestEventPoll(immediate = true)
    }

    private fun requestEventPoll(immediate: Boolean = false) {
        if (!attachedToEngine || players.isEmpty()) {
            return
        }
        immediateEventPollLatch.request(immediate)
        if (eventPollQueued.get()) {
            return
        }
        val runImmediately = immediateEventPollLatch.takeIfReady(pollInFlight = false)
        if (eventPollTimerScheduled) {
            if (!runImmediately) {
                return
            }
            mainHandler.removeCallbacks(eventPollRunnable)
            eventPollTimerScheduled = false
        }
        eventPollTimerScheduled = true
        if (runImmediately) {
            mainHandler.post(eventPollRunnable)
        } else {
            mainHandler.postDelayed(eventPollRunnable, nextEventPollDelayMillis())
        }
    }

    private fun stopEventPollingIfIdle() {
        if (players.isNotEmpty()) {
            return
        }
        mainHandler.removeCallbacks(eventPollRunnable)
        eventPollTimerScheduled = false
        eventPollIdleRounds = 0
        immediateEventPollLatch.clear()
    }

    private fun nextEventPollDelayMillis(): Long {
        val idleDelay = androidEventPollDelayMillis(
            hasActivePlayers = hasLowLatencyEventPollingPlayers(),
            idleRounds = eventPollIdleRounds,
        )
        val nowMillis = SystemClock.uptimeMillis()
        val hostRetryDelays = players.values
            .asSequence()
            .filterNot { host -> host.isDestroyed }
            .map { host -> host.eventPollBackoff.delayMillis(nowMillis) }
            .toList()
        return androidNextEventPollDelayMillis(idleDelay, hostRetryDelays)
    }

    private fun hasLowLatencyEventPollingPlayers(): Boolean = players.values.any { host ->
        host.playbackPhase == AndroidPlaybackPhase.PLAYING ||
            (host.playbackPhase == AndroidPlaybackPhase.PENDING &&
                host.mediaState.canPlay(isActivityActive))
    }

    private fun scheduleEventPoll() {
        if (!attachedToEngine || !eventPollQueued.compareAndSet(false, true)) {
            return
        }
        val pollStartedAtMillis = SystemClock.uptimeMillis()
        val pollingPlayers = players.values.toList().filter { host ->
            !host.isDestroyed && host.eventPollBackoff.delayMillis(pollStartedAtMillis) == 0L
        }
        if (pollingPlayers.isEmpty()) {
            eventPollQueued.set(false)
            if (players.values.any { host -> !host.isDestroyed }) {
                requestEventPoll()
            }
            return
        }
        val posted = presenterThread.post {
            val batches = pollingPlayers.map(::pollEventsOnPresenterThread)
            postMainSafely(
                source = "event poll completion",
                onFailure = {
                    eventPollQueued.set(false)
                    requestEventPoll()
                },
            ) main@{
                eventPollQueued.set(false)
                if (!attachedToEngine) {
                    return@main
                }
                var observedEvent = false
                val pollCompletedAtMillis = SystemClock.uptimeMillis()
                batches.forEach { batch ->
                    val host = batch.host
                    if (players[host.handle] !== host || host.isDestroyed) {
                        return@forEach
                    }
                    observedEvent = observedEvent || batch.responses.any(NativeResponse::ok)
                    host.eventPollBackoff.record(
                        failed = eventPollFailureSignature(batch) != null,
                        nowMillis = pollCompletedAtMillis,
                    )
                    processPolledEvents(batch)
                }
                eventPollIdleRounds = if (observedEvent ||
                    hasLowLatencyEventPollingPlayers()
                ) {
                    0
                } else {
                    (eventPollIdleRounds + 1).coerceAtMost(ANDROID_MAX_EVENT_POLL_IDLE_ROUNDS)
                }
                requestEventPoll()
            }
        }
        if (!posted) {
            eventPollQueued.set(false)
        }
    }

    private fun pollEventsOnPresenterThread(host: AndroidPlayerHost): AndroidPolledEvents {
        val responses = ArrayList<NativeResponse>()
        var failure: Throwable? = null
        var eventQueueDrained = false
        for (index in 0 until MAX_EVENTS_PER_POLL) {
            val response = try {
                host.pollEvent()
            } catch (error: Throwable) {
                failure = error
                null
            }
            if (response == null) {
                eventQueueDrained = failure == null
                break
            }
            responses += response
            if (!response.ok) {
                break
            }
        }
        val playbackState = try {
            host.playbackState()
        } catch (error: Throwable) {
            if (failure == null) {
                failure = error
            }
            null
        }
        val playbackIntentState = try {
            host.playbackIntentState()
        } catch (error: Throwable) {
            if (failure == null) {
                failure = error
            }
            null
        }
        return AndroidPolledEvents(
            host,
            responses,
            failure,
            host.latestExecutedContentGeneration,
            host.latestExecutedPlaybackIntentGeneration,
            playbackState,
            playbackIntentState,
            eventQueueDrained,
        )
    }

    private fun processPolledEvents(batch: AndroidPolledEvents) {
        val host = batch.host
        val acceptsContent = androidEventBatchAcceptsContent(
            eventGeneration = batch.contentGeneration,
            currentContentGeneration = host.currentContentGeneration,
        )
        val acceptsPlaybackState = acceptsContent &&
            androidEventBatchAcceptsPlaybackState(
                eventGeneration = batch.playbackIntentGeneration,
                currentIntentGeneration = host.currentPlaybackIntentGeneration,
            )
        if (!acceptsContent) {
            Log.d(
                TAG,
                "Ignoring stale content events for player ${host.handle}: " +
                    "eventGeneration=${batch.contentGeneration} " +
                    "currentGeneration=${host.currentContentGeneration}",
            )
        }
        if (!acceptsPlaybackState) {
            Log.d(
                TAG,
                "Ignoring stale playback state for player ${host.handle}: " +
                    "eventGeneration=${batch.playbackIntentGeneration} " +
                "currentGeneration=${host.currentPlaybackIntentGeneration}",
            )
        }
        val failureSignature = eventPollFailureSignature(batch)
        // Poll failures describe the presenter/host, not one media item. Queue
        // them independently of content generation so a failure observed
        // during Open cannot be permanently swallowed by stale-content
        // filtering. `shouldReport` commits the signature only when this policy
        // allows the failure to be queued.
        val reportPollFailure = host.eventPollFailures.shouldReport(
            signature = failureSignature,
            canDeliver = true,
        )
        if (reportPollFailure) {
            batch.error?.let { error ->
                Log.e(TAG, "pollEvent threw for player ${host.handle}", error)
            }
            val failedResponse = batch.responses.firstOrNull { response ->
                !response.ok && response.status != NO_EVENT_STATUS
            }
            val error = batch.error
            enqueuePendingEvent(
                host,
                AndroidPendingEvent.Error(
                    code = "ERIKA_ERROR",
                    message = error?.message
                        ?: failedResponse?.error
                        ?: "Erika event polling failed",
                    details = buildMap {
                        put("playerId", host.handle)
                        put("status", failedResponse?.status ?: -1)
                        error?.let { put("exception", it.javaClass.name) }
                    },
                    contentGeneration = null,
                ),
            )
        }
        val authoritativePlaybackState = batch.playbackState.takeIf {
            androidCanSynthesizeAuthoritativeState(batch.eventQueueDrained)
        }
        val pendingPlayTransition = acceptsPlaybackState &&
            authoritativePlaybackState?.let { playbackState ->
                androidPlaybackStateIsPendingPlayTransition(
                    playbackState = playbackState,
                    playbackIntentState = batch.playbackIntentState,
                    playingState = PLAYING_STATE,
                )
            } == true
        var latestPlaybackState: Int? = null
        var deliveredAuthoritativeState = false
        for (response in batch.responses) {
            if (!response.ok) {
                break
            }
            val rawEvent = response.value as? Map<*, *> ?: break
            val event = linkedMapOf<String, Any?>()
            rawEvent.forEach { (key, value) ->
                if (key != null) {
                    event[key.toString()] = value
                }
            }
            event.putIfAbsent("playerId", host.handle)
            val eventKind = (event["kind"] as? Number)?.toInt()
            val stateChanged = eventKind == STATE_CHANGED_EVENT_KIND
            val eventPlaybackState = (event["state"] as? Number)?.toInt()
            if (acceptsContent && eventKind == ERROR_EVENT_KIND) {
                val status = (event["status"] as? Number)?.toInt() ?: -1
                val error = event["error"] as? String
                    ?: event["message"] as? String
                    ?: "unknown native error"
                Log.e(
                    TAG,
                    "Erika error event: playerId=${host.handle} status=$status error=$error",
                )
            }
            if (!androidEventShouldBeDelivered(
                    eventKind = eventKind,
                    stateChangedEventKind = STATE_CHANGED_EVENT_KIND,
                    acceptsContent = acceptsContent,
                    acceptsPlaybackState = acceptsPlaybackState,
                    pendingPlayTransition = pendingPlayTransition,
                )
            ) {
                continue
            }
            latestPlaybackState = updatedPlaybackState(latestPlaybackState, event)
            if (stateChanged && eventPlaybackState == authoritativePlaybackState) {
                deliveredAuthoritativeState = true
            }
            val duplicateStateChanged = stateChanged &&
                androidStateChangedEventIsDuplicate(
                    currentPlaybackState = host.mediaState.playbackState,
                    eventPlaybackState = eventPlaybackState,
                )
            host.updateMediaState(event, rememberCompleteEvent = acceptsContent)
            if (!duplicateStateChanged) {
                enqueuePendingEvent(
                    host,
                    AndroidPendingEvent.Success(
                        value = event,
                        contentGeneration = androidPendingEventContentGeneration(
                            eventKind,
                            batch.contentGeneration,
                        ),
                    ),
                )
            }
        }
        if (acceptsPlaybackState && authoritativePlaybackState != null && !pendingPlayTransition) {
            val authoritativeEvent = androidAuthoritativeStateEvent(
                lastCompleteEvent = host.completeNativeEventSnapshot(),
                playerId = host.handle,
                stateChangedEventKind = STATE_CHANGED_EVENT_KIND,
                state = authoritativePlaybackState,
                durationMicros = host.mediaState.durationMicros,
                positionMicros = host.mediaState.positionMicros,
            )
            val stateChanged = host.mediaState.playbackState != authoritativePlaybackState
            host.updateMediaState(authoritativeEvent)
            if (stateChanged && !deliveredAuthoritativeState) {
                enqueuePendingEvent(
                    host,
                    AndroidPendingEvent.Success(
                        value = authoritativeEvent,
                        contentGeneration = batch.contentGeneration,
                    ),
                )
            }
        }
        if (acceptsPlaybackState) {
            (authoritativePlaybackState ?: latestPlaybackState)?.let { state ->
                observeNativePlaybackState(host, state, batch.playbackIntentState)
            }
        }
        if (acceptsContent && activeMediaPlayerId == host.handle) {
            val mediaSessionPlaybackState = androidMediaSessionPlaybackState(
                playbackState = host.mediaState.playbackState,
                playbackIntentState = batch.playbackIntentState,
                playingState = PLAYING_STATE,
                acceptsPlaybackState = acceptsPlaybackState,
            )
            mediaSession.update(
                if (mediaSessionPlaybackState == host.mediaState.playbackState) {
                    host.mediaState
                } else {
                    host.mediaState.copy(playbackState = mediaSessionPlaybackState)
                },
            )
        }
        flushPendingEvents(host)
    }

    private fun eventPollFailureSignature(batch: AndroidPolledEvents): String? {
        batch.error?.let { error ->
            return "exception:${error.javaClass.name}:${error.message.orEmpty()}"
        }
        val response = batch.responses.firstOrNull { candidate ->
            !candidate.ok && candidate.status != NO_EVENT_STATUS
        } ?: return null
        return "response:${response.status}:${response.error.orEmpty()}"
    }

    private fun setMediaMetadata(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val host = player(arguments)
        host.setMediaMetadata(androidMediaMetadata(arguments))
        if (activeMediaPlayerId == host.handle) {
            mediaSession.update(host.mediaState)
        }
        result.success(null)
    }

    private fun setSystemMediaNavigation(
        arguments: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val host = player(arguments)
        host.setSystemMediaNavigation(arguments)
        if (activeMediaPlayerId == host.handle) {
            mediaSession.update(host.mediaState)
        }
        result.success(null)
    }

    private fun emitSystemMediaNavigation(playerId: Long, navigation: String) {
        val host = players[playerId] ?: return
        val event = systemMediaNavigationEvent(host.mediaState, navigation) ?: return
        enqueuePendingEvent(
            host,
            AndroidPendingEvent.Success(
                value = event,
                contentGeneration = host.currentContentGeneration,
            ),
        )
        flushPendingEvents(host)
    }

    private fun performSystemMediaCommand(
        playerId: Long,
        method: String,
        arguments: Map<String, Any?> = emptyMap(),
    ) {
        val host = players[playerId] ?: return
        if (method == "play") {
            if (!host.mediaState.canPlay(isActivityActive)) {
                return
            }
            host.requestPlayback()
            refreshFrameScheduling()
            when (runCatching { audioFocus.request() }.getOrNull()) {
                AudioFocusGrant.GRANTED -> startPendingPlayback(host, "system media")
                AudioFocusGrant.DELAYED -> Unit
                else -> {
                    host.cancelPlaybackIntentLocally()
                    abandonAudioFocusIfIdle()
                    refreshFrameScheduling()
                }
            }
            return
        }
        if (method in PLAYBACK_INTENT_CANCEL_METHODS) {
            host.cancelPlaybackIntent(forceNewGeneration = true)
            abandonAudioFocusIfIdle()
        }
        if (method in CONTENT_PREPARATION_INVALIDATION_METHODS) {
            host.cancelContentPreparations("superseded_by_system_$method")
        }
        refreshFrameScheduling()
        postBackgroundCommand(host, "system media", method, arguments)
    }

    private fun observeNativePlaybackState(
        host: AndroidPlayerHost,
        state: Int,
        playbackIntentState: Int?,
    ) {
        if (
            androidPlaybackStateIsPendingPlayTransition(
                playbackState = state,
                playbackIntentState = playbackIntentState,
                playingState = PLAYING_STATE,
            )
        ) {
            // Player::play is accepted synchronously but committed by the Rust
            // playback worker. Ready/Paused/Stopped is therefore a legitimate
            // transient actual state while the latest native intent is Playing.
            refreshFrameScheduling()
            return
        }
        when (state) {
            PLAYING_STATE -> {
                if (isActivityActive &&
                    audioFocus.focusGranted &&
                    host.playbackPhase == AndroidPlaybackPhase.PENDING
                ) {
                    host.playbackStarted()
                }
            }
            PAUSED_STATE -> {
                if (host.playbackPhase == AndroidPlaybackPhase.PLAYING) {
                    host.reconcileNativePlaybackStopped()
                    abandonAudioFocusIfIdle()
                }
            }
            STOPPED_STATE,
            CLOSED_STATE,
            ERROR_STATE -> {
                host.reconcileNativePlaybackStopped()
                abandonAudioFocusIfIdle()
            }
        }
        refreshFrameScheduling()
    }

    private fun complete(result: MethodChannel.Result, response: NativeResponse) {
        if (response.ok) {
            result.success(response.value)
        } else {
            result.error(
                "ERIKA_ERROR",
                response.error ?: "Erika native call failed with status ${response.status}",
                mapOf("status" to response.status),
            )
        }
    }

    private fun deliverSurfaceMethodResult(
        operation: String,
        result: MethodChannel.Result,
        response: NativeResponse,
        successValue: Any? = null,
    ) {
        runCatching {
            if (response.ok) {
                result.success(successValue)
            } else {
                complete(result, response)
            }
        }.onFailure { error ->
            Log.e(TAG, "Unable to deliver asynchronous $operation result", error)
        }
    }

    private fun player(arguments: Map<String, Any?>): AndroidPlayerHost {
        val playerId = arguments.requiredLong("playerId")
        return players[playerId]
            ?: throw IllegalStateException("Erika Android player $playerId was not found")
    }

    private fun arguments(call: MethodCall): Map<String, Any?> {
        val raw = call.arguments as? Map<*, *> ?: return emptyMap()
        return buildMap {
            raw.forEach { (key, value) ->
                if (key != null) {
                    put(key.toString(), value)
                }
            }
        }
    }

    private fun newContentPreparationExecutor(): ExecutorService =
        Executors.newFixedThreadPool(CONTENT_PREPARATION_THREADS) { runnable ->
            Thread(
                runnable,
                "erika-content-${CONTENT_PREPARATION_THREAD_IDS.getAndIncrement()}",
            ).apply {
                isDaemon = true
            }
        }

    private fun newImageDecodeExecutor(policy: AndroidImagePolicy): ThreadPoolExecutor =
        ThreadPoolExecutor(
            policy.maxConcurrentDecodes,
            policy.maxConcurrentDecodes,
            0L,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue(policy.maxQueuedDecodes),
            { runnable ->
                Thread(runnable, "erika-image-decode").apply { isDaemon = true }
            },
            ThreadPoolExecutor.AbortPolicy(),
        )

    private fun validateImagePolicy(policy: AndroidImagePolicy) {
        require(policy.maxEncodedBytes in 1..HARD_MAX_IMAGE_ENCODED_BYTES)
        require(policy.maxSourcePixels in 1..HARD_MAX_IMAGE_SOURCE_PIXELS)
        require(policy.maxOutputPixels in 1..HARD_MAX_IMAGE_OUTPUT_PIXELS)
        require(policy.maxPacketsBeforeFrame in 1..HARD_MAX_IMAGE_PACKETS_BEFORE_FRAME)
        require(policy.decodeTimeoutMillis in 1..HARD_MAX_IMAGE_DECODE_TIMEOUT_MILLIS)
        require(policy.maxQueuedDecodes in 1..HARD_MAX_IMAGE_QUEUE_DEPTH)
        require(policy.maxConcurrentDecodes in 1..HARD_MAX_IMAGE_CONCURRENT_DECODES)
    }

    private fun scheduleContentSpoolStartupScavenge(): Future<*>? = try {
        contentPreparationExecutor.submit {
            val startedAt = SystemClock.elapsedRealtime()
            try {
                // cacheDir access and directory enumeration both stay off the platform thread.
                val directory = File(applicationContext.cacheDir, ANDROID_CONTENT_SPOOL_DIRECTORY)
                val stats = scavengeAndroidContentSpoolDirectory(directory)
                val event = androidContentSourceEvent(
                    stage = "startup_scavenge",
                    authority = null,
                    fields = linkedMapOf(
                        "mode" to "cache_spool",
                        "execution" to "background",
                        "files" to stats.files,
                        "bytes" to stats.bytes,
                        "deleteFailures" to stats.deleteFailures,
                        "elapsedMs" to SystemClock.elapsedRealtime() - startedAt,
                    ),
                )
                if (stats.deleteFailures == 0) {
                    Log.i(TAG, event)
                } else {
                    Log.w(TAG, event)
                }
            } catch (error: Throwable) {
                Log.e(
                    TAG,
                    androidContentSourceEvent(
                        stage = "startup_scavenge",
                        authority = null,
                        fields = linkedMapOf(
                            "mode" to "cache_spool",
                            "execution" to "background",
                            "files" to 0,
                            "bytes" to 0L,
                            "deleteFailures" to 0,
                            "reason" to "scan_failed",
                            "message" to (error.message ?: error.javaClass.simpleName),
                            "elapsedMs" to SystemClock.elapsedRealtime() - startedAt,
                        ),
                    ),
                    error,
                )
            }
        }
    } catch (error: RejectedExecutionException) {
        Log.e(
            TAG,
            androidContentSourceEvent(
                stage = "startup_scavenge",
                authority = null,
                fields = linkedMapOf(
                    "mode" to "cache_spool",
                    "execution" to "not_started",
                    "files" to 0,
                    "bytes" to 0L,
                    "deleteFailures" to 0,
                    "reason" to "executor_unavailable",
                ),
            ),
            error,
        )
        null
    }

    private fun awaitContentSpoolStartupScavenge(
        cancellation: AndroidContentPreparationCancellation,
    ) {
        val future = contentSpoolScavengeFuture ?: return
        try {
            future.get()
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw AndroidContentPreparationCancelledException(
                "Android content preparation was interrupted before startup cache cleanup",
            )
        } catch (error: CancellationException) {
            throw AndroidContentPreparationCancelledException(
                "Android content startup cache cleanup was cancelled",
            )
        } catch (error: Throwable) {
            throw IOException("Android content startup cache cleanup failed", error)
        }
        cancellation.throwIfCancelled()
    }

    private class PendingContentCommand(
        val host: AndroidPlayerHost,
        val method: String,
        val authority: String?,
        val result: MethodChannel.Result,
        val cancellation: AndroidContentPreparationCancellation,
        val playbackIntentGeneration: Long?,
        val contentGeneration: Long?,
    ) {
        lateinit var token: AndroidContentPreparationToken
        private var completed = false

        fun claimCompletion(): Boolean {
            if (completed) {
                return false
            }
            completed = true
            return true
        }
    }

    private data class PreparedNativeArguments(
        val arguments: Map<String, Any?>,
        val detachedFd: Int?,
    )

    private data class DetachedContentSource(
        val fd: Int,
        val uri: String,
    )

    private data class ContentDescriptorProbe(
        val transport: AndroidContentTransport,
        val endOffset: Long?,
        val fallbackReason: String?,
    )

    private data class AndroidRenderRequest(
        val timeSeconds: Double,
        val targets: List<AndroidRenderTarget>,
        val generation: Long,
    )

    private data class AndroidRenderTarget(
        val host: AndroidPlayerHost,
        val renderRequestGeneration: Long,
    )

    private data class AndroidRenderOutcome(
        val host: AndroidPlayerHost,
        val renderRequestGeneration: Long,
        val contentGeneration: Long,
        val response: NativeResponse?,
        val error: Throwable?,
    )

    private data class AndroidPolledEvents(
        val host: AndroidPlayerHost,
        val responses: List<NativeResponse>,
        val error: Throwable?,
        val contentGeneration: Long,
        val playbackIntentGeneration: Long,
        val playbackState: Int?,
        val playbackIntentState: Int?,
        val eventQueueDrained: Boolean,
    )

    private data class PendingPlayKey(
        val host: AndroidPlayerHost,
        val intentGeneration: Long,
    )

    companion object {
        private const val TAG = "ErikaFlutterPlugin"
        private const val PLAYER_CHANNEL = "erika_flutter/player"
        private const val EVENT_CHANNEL = "erika_flutter/events"
        private const val VIDEO_VIEW_TYPE = "erika_flutter/video_view"
        private const val HDR_VIDEO_VIEW_TYPE = "erika_flutter/hdr_video_view"
        private const val HDR_IMAGE_VIEW_TYPE = "erika_flutter/hdr_image_view"
        private const val MAX_EVENTS_PER_POLL = 256
        private const val EVENT_OVERFLOW_LOG_INTERVAL = 256L
        private const val NO_EVENT_STATUS = 5
        private const val ERROR_EVENT_KIND = 9
        private const val PLAYING_STATE = 3
        private const val PAUSED_STATE = 4
        private const val STOPPED_STATE = 5
        private const val CLOSED_STATE = 6
        private const val ERROR_STATE = 7
        private const val NO_OWNED_FD = -1
        private const val CONTENT_PREPARATION_THREADS = 2
        private const val HARD_MAX_IMAGE_QUEUE_DEPTH = 64
        private const val HARD_MAX_IMAGE_CONCURRENT_DECODES = 4
        private const val HARD_MAX_IMAGE_ENCODED_BYTES = 128L * 1024L * 1024L
        private const val HARD_MAX_IMAGE_SOURCE_PIXELS = 32L * 1024L * 1024L
        private const val HARD_MAX_IMAGE_OUTPUT_PIXELS = 32L * 1024L * 1024L
        private const val HARD_MAX_IMAGE_PACKETS_BEFORE_FRAME = 4_096
        private const val HARD_MAX_IMAGE_DECODE_TIMEOUT_MILLIS = 120_000L
        private val DEFAULT_IMAGE_POLICY = AndroidImagePolicy(
            maxEncodedBytes = HARD_MAX_IMAGE_ENCODED_BYTES,
            maxSourcePixels = HARD_MAX_IMAGE_SOURCE_PIXELS,
            maxOutputPixels = HARD_MAX_IMAGE_OUTPUT_PIXELS,
            maxPacketsBeforeFrame = 256,
            decodeTimeoutMillis = 15_000L,
            maxQueuedDecodes = 8,
            maxConcurrentDecodes = 1,
        )
        private const val IMAGE_ERROR_SOURCE = 4
        private const val IMAGE_ERROR_CANCELLED = 6
        private const val IMAGE_ERROR_RESOURCE_LIMIT = 7
        private const val IMAGE_ERROR_RENDERER = 8
        private const val IMAGE_ERROR_BUSY = 10
        private const val IMAGE_ERROR_INTERNAL = 9
        private val CONTENT_PREPARATION_THREAD_IDS = AtomicInteger(1)
        private val NEXT_NATIVE_IMAGE_OPERATION_ID = AtomicLong(1L)

        private fun nextNativeImageOperationId(): Long {
            while (true) {
                val candidate = NEXT_NATIVE_IMAGE_OPERATION_ID.get()
                check(candidate in 1 until Long.MAX_VALUE) {
                    "native image operation id space is exhausted"
                }
                if (NEXT_NATIVE_IMAGE_OPERATION_ID.compareAndSet(candidate, candidate + 1L)) {
                    return candidate
                }
            }
        }

        private val URI_METHODS = setOf(
            "open",
            "addExternalSubtitle",
            "loadDanmakuFile",
            "addDanmakuTrackFile",
        )

        private val PLAYBACK_INTENT_CANCEL_METHODS = setOf(
            "open",
            "pause",
            "stop",
            "close",
        )

        private val CONTENT_PREPARATION_INVALIDATION_METHODS = setOf(
            "open",
            "stop",
            "close",
        )

        private val RENDER_REQUEST_METHODS = setOf(
            "open",
            "stop",
            "close",
            "seek",
            "setUpscaler",
            "setSubtitleScale",
            "setSubtitleStyle",
            "selectSubtitleMemoryFonts",
            "clearSubtitleMemoryFonts",
            "addExternalSubtitle",
            "removeSubtitleTrack",
            "loadDanmakuFile",
            "loadDanmakuJson",
            "addDanmakuTrackFile",
            "addDanmakuTrackJson",
            "removeDanmakuTrack",
            "setDanmakuTrackEnabled",
            "setDanmakuTrackOffset",
            "setDanmakuGlobalOffset",
            "clearDanmaku",
            "setDanmakuEnabled",
            "setDanmakuConfig",
            "setDebugHudEnabled",
            "selectAudioTrack",
            "selectSubtitleTrack",
        )

        private val NATIVE_METHODS = setOf(
            "open",
            "play",
            "pause",
            "stop",
            "close",
            "seek",
            "setPlaybackRate",
            "setVolume",
            "setUpscaler",
            "setSubtitleScale",
            "setSubtitleStyle",
            "selectSubtitleMemoryFonts",
            "clearSubtitleMemoryFonts",
            "getSubtitleMemoryFontStatus",
            "getUpscalerStatus",
            "getOutputStatus",
            "getPresenterStats",
            "getResourceStatus",
            "setDebugHudEnabled",
            "addExternalSubtitle",
            "removeSubtitleTrack",
            "loadDanmakuFile",
            "loadDanmakuJson",
            "addDanmakuTrackFile",
            "addDanmakuTrackJson",
            "removeDanmakuTrack",
            "setDanmakuTrackEnabled",
            "setDanmakuTrackOffset",
            "setDanmakuGlobalOffset",
            "danmakuTracks",
            "clearDanmaku",
            "setDanmakuEnabled",
            "setDanmakuConfig",
            "selectAudioTrack",
            "selectSubtitleTrack",
            "tracks",
        )
    }
}

private fun Map<String, Any?>.number(key: String): Number? = this[key] as? Number

private fun Map<String, Any?>.int(key: String): Int? = number(key)?.toInt()

private fun Map<String, Any?>.requiredInt(key: String): Int =
    int(key) ?: throw IllegalArgumentException("Missing integer argument '$key'")

private fun Map<String, Any?>.requiredLong(key: String): Long =
    number(key)?.toLong() ?: throw IllegalArgumentException("Missing integer argument '$key'")
