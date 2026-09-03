package dev.aimesoft.erika_flutter

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal class ErikaAndroidHdrImageViewFactory(
    private val plugin: ErikaFlutterPlugin,
    private val engineGeneration: Long,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val values = args as? Map<String, Any?> ?: emptyMap()
        return ErikaAndroidHdrImageView(
            context,
            viewId,
            (values["imageId"] as Number).toLong(),
            values["composition"] == "hybrid",
            engineGeneration,
            plugin,
        )
    }
}

internal class ErikaAndroidHdrImageView(
    context: Context,
    private val viewId: Int,
    private val imageId: Long,
    private val directComposition: Boolean,
    private val engineGeneration: Long,
    private val plugin: ErikaFlutterPlugin,
) : PlatformView, SurfaceHolder.Callback {
    private val surfaceView = SurfaceView(context).apply {
        holder.setFormat(PixelFormat.RGBA_F16)
        holder.addCallback(this@ErikaAndroidHdrImageView)
    }
    private var disposed = false
    private var generation = 0L

    init { plugin.registerHdrImageView(viewId, engineGeneration) }

    override fun getView(): View = surfaceView

    override fun surfaceCreated(holder: SurfaceHolder) = attach(holder)

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (!disposed && generation > 0) {
            plugin.resizeHdrImageSurface(
                imageId,
                viewId,
                engineGeneration,
                generation,
                width.coerceAtLeast(1),
                height.coerceAtLeast(1),
            )
        }
    }

    private fun attach(holder: SurfaceHolder) {
        if (disposed) return
        val activeGeneration = ++generation
        val frame = holder.surfaceFrame
        val displayHdrSupported = if (Build.VERSION.SDK_INT >= 24) {
            surfaceView.display?.isHdr == true
        } else {
            false
        }
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = true,
            sdkInt = Build.VERSION.SDK_INT,
            displayHdrSupported = displayHdrSupported,
            directComposition = directComposition,
        )
        plugin.attachHdrImageSurface(
            imageId,
            holder.surface,
            frame.width().coerceAtLeast(1),
            frame.height().coerceAtLeast(1),
            decision.extendedLinearEligible,
            decision.fallbackReason,
            directComposition,
            viewId,
            engineGeneration,
            activeGeneration,
        ) { response ->
            if (!disposed && generation == activeGeneration) {
                plugin.reportHdrImageSurfaceEvent(
                    viewId,
                    imageId,
                    engineGeneration,
                    response,
                )
            }
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        generation += 1
        val barrier = CountDownLatch(1)
        plugin.detachHdrImageSurface(imageId, viewId, engineGeneration, generation) {
            barrier.countDown()
        }
        if (!barrier.await(ANDROID_SURFACE_DESTROY_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)) {
            Log.e("ErikaHdrImageView", "Timed out detaching image $imageId view $viewId")
        }
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        surfaceView.holder.removeCallback(this)
        generation += 1
        plugin.detachHdrImageSurface(imageId, viewId, engineGeneration, generation) {
            plugin.unregisterHdrImageView(viewId, engineGeneration)
        }
    }
}
