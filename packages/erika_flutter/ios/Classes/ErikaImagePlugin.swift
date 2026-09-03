import Flutter
import CoreVideo
import Metal
import QuartzCore
import UIKit

private let erikaImageHardMaxEncodedBytes = 128 * 1024 * 1024
private let erikaImageHardMaxPixels = 32 * 1024 * 1024
private let erikaImageHardMaxPacketsBeforeFrame = 4096
private let erikaImageHardMaxDecodeTimeoutMillis = 120_000
private let erikaImageHardMaxQueuedDecodes = 64
private let erikaImageHardMaxConcurrentDecodes = 4
private let erikaImageErrorCancelled = 6
private let erikaImageErrorResourceLimit = 7
private let erikaImageErrorRenderer = 8
private let erikaImageErrorInternal = 9
private let erikaImageErrorBusy = 10
private let erikaDisplayHdrUnsupported = 1

fileprivate enum ErikaIOSImagePolicyError: Error, CustomStringConvertible {
  case invalid

  var description: String { "invalid image pipeline policy" }
}

fileprivate struct ErikaIOSImagePolicy {
  let maxEncodedBytes: Int
  let maxSourcePixels: Int
  let maxOutputPixels: Int
  let maxPacketsBeforeFrame: Int
  let decodeTimeoutMillis: Int
  let maxQueuedDecodes: Int
  let maxConcurrentDecodes: Int

  static let `default` = ErikaIOSImagePolicy(
    maxEncodedBytes: erikaImageHardMaxEncodedBytes,
    maxSourcePixels: erikaImageHardMaxPixels,
    maxOutputPixels: erikaImageHardMaxPixels,
    maxPacketsBeforeFrame: 256,
    decodeTimeoutMillis: 15_000,
    maxQueuedDecodes: 8,
    maxConcurrentDecodes: 1
  )

  init(arguments: [String: Any]) throws {
    maxEncodedBytes = integer(arguments["maxEncodedBytes"])
    maxSourcePixels = integer(arguments["maxSourcePixels"])
    maxOutputPixels = integer(arguments["maxOutputPixels"])
    maxPacketsBeforeFrame = integer(arguments["maxPacketsBeforeFrame"])
    decodeTimeoutMillis = integer(arguments["decodeTimeoutMillis"])
    maxQueuedDecodes = integer(arguments["maxQueuedDecodes"])
    maxConcurrentDecodes = integer(arguments["maxConcurrentDecodes"])
    guard maxEncodedBytes > 0, maxEncodedBytes <= erikaImageHardMaxEncodedBytes,
          maxSourcePixels > 0, maxSourcePixels <= erikaImageHardMaxPixels,
          maxOutputPixels > 0, maxOutputPixels <= erikaImageHardMaxPixels,
          maxPacketsBeforeFrame > 0,
          maxPacketsBeforeFrame <= erikaImageHardMaxPacketsBeforeFrame,
          decodeTimeoutMillis > 0,
          decodeTimeoutMillis <= erikaImageHardMaxDecodeTimeoutMillis,
          maxQueuedDecodes > 0, maxQueuedDecodes <= erikaImageHardMaxQueuedDecodes,
          maxConcurrentDecodes > 0,
          maxConcurrentDecodes <= erikaImageHardMaxConcurrentDecodes else {
      throw ErikaIOSImagePolicyError.invalid
    }
  }

  private init(
    maxEncodedBytes: Int,
    maxSourcePixels: Int,
    maxOutputPixels: Int,
    maxPacketsBeforeFrame: Int,
    decodeTimeoutMillis: Int,
    maxQueuedDecodes: Int,
    maxConcurrentDecodes: Int
  ) {
    self.maxEncodedBytes = maxEncodedBytes
    self.maxSourcePixels = maxSourcePixels
    self.maxOutputPixels = maxOutputPixels
    self.maxPacketsBeforeFrame = maxPacketsBeforeFrame
    self.decodeTimeoutMillis = decodeTimeoutMillis
    self.maxQueuedDecodes = maxQueuedDecodes
    self.maxConcurrentDecodes = maxConcurrentDecodes
  }
}

/// Process-wide allocator. Dart operation ids restart from one for each
/// isolate, while the C cancellation registry is process-global.
private enum ErikaIOSNativeImageOperationIds {
  private static let lock = NSLock()
  private static var next: UInt64 = 1

  static func allocate() -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    guard next > 0, next < UInt64.max else { return nil }
    let value = next
    next += 1
    return value
  }
}

fileprivate enum ErikaIOSImageDecodeKind {
  case automatic
  case sdr
  case hdr
}

fileprivate final class ErikaIOSImageDecodeJob {
  let dartOperationId: UInt64
  let nativeOperationId: UInt64
  let kind: ErikaIOSImageDecodeKind
  let path: String
  let maxWidth: UInt32
  let maxHeight: UInt32
  let policy: ErikaIOSImagePolicy
  let hdrSurfaceSupported: Bool
  let result: FlutterResult
  let subsystemGeneration: UInt64
  var cancelled = false
  var delivered = false

  init(
    dartOperationId: UInt64,
    nativeOperationId: UInt64,
    kind: ErikaIOSImageDecodeKind,
    path: String,
    maxWidth: UInt32,
    maxHeight: UInt32,
    policy: ErikaIOSImagePolicy,
    hdrSurfaceSupported: Bool,
    subsystemGeneration: UInt64,
    result: @escaping FlutterResult
  ) {
    self.dartOperationId = dartOperationId
    self.nativeOperationId = nativeOperationId
    self.kind = kind
    self.path = path
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.policy = policy
    self.hdrSurfaceSupported = hdrSurfaceSupported
    self.subsystemGeneration = subsystemGeneration
    self.result = result
  }
}

fileprivate struct ErikaIOSEdrCapability: Equatable {
  let eligible: Bool
  let desiredHeadroom: Float
  let fallbackReason: Int32
}

fileprivate struct ErikaIOSImageSurfaceMetrics: Equatable {
  let width: UInt32
  let height: UInt32
  let scale: Double
  let currentHeadroom: Float
  let capability: ErikaIOSEdrCapability
}

fileprivate struct ErikaIOSImageSurfaceOwner: Equatable {
  let viewId: Int64
  let generation: UInt64
}

fileprivate final class ErikaIOSImageSurfaceRecord {
  let owner: ErikaIOSImageSurfaceOwner
  let layer: CAMetalLayer

  init(owner: ErikaIOSImageSurfaceOwner, layer: CAMetalLayer) {
    self.owner = owner
    self.layer = layer
  }
}

fileprivate final class ErikaIOSSdrTexture: NSObject, FlutterTexture {
  let pixelBuffer: CVPixelBuffer

  init?(rgba: Data, width: Int, height: Int, sourceRowBytes: Int) {
    guard width > 0, height > 0, sourceRowBytes >= width * 4,
          rgba.count >= sourceRowBytes * height else {
      return nil
    }
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var created: CVPixelBuffer?
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &created
    ) == kCVReturnSuccess, let created else {
      return nil
    }
    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    guard let destinationBase = CVPixelBufferGetBaseAddress(created) else { return nil }
    let destinationRowBytes = CVPixelBufferGetBytesPerRow(created)
    rgba.withUnsafeBytes { raw in
      guard let sourceBase = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      let destination = destinationBase.assumingMemoryBound(to: UInt8.self)
      for row in 0..<height {
        let sourceRow = sourceBase.advanced(by: row * sourceRowBytes)
        let destinationRow = destination.advanced(by: row * destinationRowBytes)
        for column in 0..<width {
          let sourcePixel = sourceRow.advanced(by: column * 4)
          let destinationPixel = destinationRow.advanced(by: column * 4)
          destinationPixel[0] = sourcePixel[2]
          destinationPixel[1] = sourcePixel[1]
          destinationPixel[2] = sourcePixel[0]
          destinationPixel[3] = sourcePixel[3]
        }
      }
    }
    pixelBuffer = created
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    Unmanaged.passRetained(pixelBuffer)
  }
}

/// Owns the iOS static-image queues and handles. This subsystem deliberately
/// has no reference to `ErikaPlayerHost`; a still image cannot create a player,
/// audio session, display link, or video timeline.
final class ErikaIOSImageSubsystem {
  private let channel: FlutterMethodChannel
  private let textureRegistry: FlutterTextureRegistry
  private let stateLock = NSLock()
  private let decodeQueue = DispatchQueue(
    label: "dev.aimesoft.erika.image.decode.ios",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let surfaceQueue = DispatchQueue(
    label: "dev.aimesoft.erika.image.surface.ios",
    qos: .userInteractive
  )
  private var pending: [ErikaIOSImageDecodeJob] = []
  private var inflight: [UInt64: ErikaIOSImageDecodeJob] = [:]
  private var nativeOperationIdsByDartId: [UInt64: UInt64] = [:]
  private var closing = false
  private var lifecycleGeneration: UInt64 = 1
  private var hdrReservation: UInt64?
  private var hdrHandles = Set<UInt64>()
  private var sdrTextures: [Int64: ErikaIOSSdrTexture] = [:]
  private var disposingHandles = Set<UInt64>()
  private var surfaceOwners: [UInt64: ErikaIOSImageSurfaceRecord] = [:]
  private var registeredViewIds = Set<Int64>()
  private var activeViewGenerations: [Int64: UInt64] = [:]
  private var decodeCount: UInt64 = 0
  private var queuedCancelled: UInt64 = 0
  private var activeHandleCount = 0
  private var policy = ErikaIOSImagePolicy.default

  init(channel: FlutterMethodChannel, textureRegistry: FlutterTextureRegistry) {
    self.channel = channel
    self.textureRegistry = textureRegistry
  }

  func capabilities(_ result: @escaping FlutterResult) {
    stateLock.lock()
    let currentPolicy = policy
    stateLock.unlock()
    result([
      "sdrDecodeSupported": true,
      "hdrSurfaceSupported": {
        guard #available(iOS 16.0, *) else { return false }
        return UIScreen.main.potentialEDRHeadroom > 1.0
      }(),
      "networkSourceSupported": false,
      "activeBackend": "software",
      "maxEncodedBytes": currentPolicy.maxEncodedBytes,
      "maxSourcePixels": currentPolicy.maxSourcePixels,
      "maxOutputPixels": currentPolicy.maxOutputPixels,
      "maxConcurrentDecodes": currentPolicy.maxConcurrentDecodes,
    ])
  }

  func configure(_ arguments: [String: Any], result: @escaping FlutterResult) throws {
    let nextPolicy = try ErikaIOSImagePolicy(arguments: arguments)
    stateLock.lock()
    guard pending.isEmpty, inflight.isEmpty else {
      stateLock.unlock()
      result(imageFlutterError(
        kind: erikaImageErrorBusy,
        message: "cannot reconfigure the image pipeline while decode jobs are active"
      ))
      return
    }
    policy = nextPolicy
    stateLock.unlock()
    result(nil)
  }

  func decodeSdr(_ arguments: [String: Any], result: @escaping FlutterResult) {
    enqueue(arguments, kind: .sdr, result: result)
  }

  func decodeImage(_ arguments: [String: Any], result: @escaping FlutterResult) {
    enqueue(arguments, kind: .automatic, result: result)
  }

  func disposeSdrTexture(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let textureId = int64(arguments["textureId"]), textureId >= 0 else {
      result(imageFlutterError(kind: erikaImageErrorInternal, message: "textureId is required"))
      return
    }
    stateLock.lock()
    let texture = sdrTextures.removeValue(forKey: textureId)
    stateLock.unlock()
    guard texture != nil else {
      result(nil)
      return
    }
    textureRegistry.unregisterTexture(textureId)
    result(nil)
  }

  func decodeHdr(_ arguments: [String: Any], result: @escaping FlutterResult) {
    enqueue(arguments, kind: .hdr, result: result)
  }

  func cancel(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let dartOperationId = uint64(arguments["operationId"]), dartOperationId > 0 else {
      result(imageFlutterError(kind: erikaImageErrorInternal, message: "operationId is required"))
      return
    }

    var queuedJob: ErikaIOSImageDecodeJob?
    var activeJob: ErikaIOSImageDecodeJob?
    stateLock.lock()
    if let index = pending.firstIndex(where: { $0.dartOperationId == dartOperationId }) {
      queuedJob = pending.remove(at: index)
      queuedJob?.cancelled = true
      queuedCancelled &+= 1
      if hdrReservation == dartOperationId {
        hdrReservation = nil
      }
    } else if let job = inflight[dartOperationId] {
      activeJob = job
      activeJob?.cancelled = true
    }
    if let job = queuedJob ?? activeJob,
       nativeOperationIdsByDartId[dartOperationId] == job.nativeOperationId {
      nativeOperationIdsByDartId.removeValue(forKey: dartOperationId)
    }
    stateLock.unlock()

    if let queuedJob {
      deliverFailure(queuedJob, kind: erikaImageErrorCancelled, message: "image decode was cancelled")
    }
    if let activeJob {
      _ = ErikaImageNativeBridge.cancel(operationId: activeJob.nativeOperationId)
      deliverFailure(activeJob, kind: erikaImageErrorCancelled, message: "image decode was cancelled")
    }
    result(nil)
  }

  func diagnostics(
    _ result: @escaping FlutterResult,
    playerCount: Int,
    videoViewCount: Int
  ) {
    stateLock.lock()
    let value: [String: Any] = [
      "queued": pending.count,
      "inflight": inflight.count,
      "decodeCount": Int64(clamping: decodeCount),
      "queuedCancelled": Int64(clamping: queuedCancelled),
      "nativeHandleCount": activeHandleCount + sdrTextures.count,
      "sdrTextureCount": sdrTextures.count,
      "playerCount": playerCount,
      "platformViewCount": videoViewCount + registeredViewIds.count,
    ]
    stateLock.unlock()
    result(value)
  }

  func disposeHdr(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let imageId = uint64(arguments["imageId"]), imageId > 0 else {
      result(imageFlutterError(kind: erikaImageErrorInternal, message: "imageId is required"))
      return
    }

    stateLock.lock()
    guard hdrHandles.contains(imageId) else {
      stateLock.unlock()
      result(nil)
      return
    }
    guard disposingHandles.insert(imageId).inserted else {
      stateLock.unlock()
      result(imageFlutterError(kind: erikaImageErrorBusy, message: "image cleanup is already active"))
      return
    }
    let callGeneration = lifecycleGeneration
    stateLock.unlock()

    surfaceQueue.async { [weak self] in
      guard let self else { return }
      _ = ErikaImageNativeBridge.detachSurface(handle: imageId)
      let response = ErikaImageNativeBridge.destroy(handle: imageId)
      self.stateLock.lock()
      self.disposingHandles.remove(imageId)
      if bridgeSucceeded(response), self.hdrHandles.remove(imageId) != nil {
        self.activeHandleCount = max(0, self.activeHandleCount - 1)
      }
      self.surfaceOwners.removeValue(forKey: imageId)
      self.stateLock.unlock()
      DispatchQueue.main.async { [weak self] in
        guard self?.isGenerationActive(callGeneration) == true else { return }
        if bridgeSucceeded(response) {
          result(nil)
        } else {
          result(imageFlutterError(from: response, defaultKind: erikaImageErrorRenderer))
        }
      }
    }
  }

  func registerHdrView(_ viewId: Int64) {
    stateLock.lock()
    if !closing {
      registeredViewIds.insert(viewId)
      activeViewGenerations[viewId] = 0
    }
    stateLock.unlock()
  }

  func unregisterHdrView(_ viewId: Int64) {
    stateLock.lock()
    registeredViewIds.remove(viewId)
    activeViewGenerations.removeValue(forKey: viewId)
    stateLock.unlock()
  }

  func activateHdrView(_ viewId: Int64, generation: UInt64) {
    stateLock.lock()
    if !closing, registeredViewIds.contains(viewId) {
      activeViewGenerations[viewId] = generation
    }
    stateLock.unlock()
  }

  func deactivateHdrView(_ viewId: Int64, generation: UInt64) {
    stateLock.lock()
    if activeViewGenerations[viewId] == generation {
      activeViewGenerations[viewId] = 0
    }
    stateLock.unlock()
  }

  fileprivate func attachHdrSurface(
    imageId: UInt64,
    viewId: Int64,
    generation: UInt64,
    layer: CAMetalLayer,
    metrics: ErikaIOSImageSurfaceMetrics,
    currentHeadroom: Float,
    headroomProvider: @escaping () -> Float
  ) {
    let owner = ErikaIOSImageSurfaceOwner(viewId: viewId, generation: generation)
    surfaceQueue.async { [weak self, layer] in
      guard let self else { return }
      self.stateLock.lock()
      let open = !self.closing
      let currentGeneration = self.activeViewGenerations[viewId] == generation
      let knownHandle = self.hdrHandles.contains(imageId)
      let existingRecord = self.surfaceOwners[imageId]
      let existingOwner = existingRecord?.owner
      if open && currentGeneration && knownHandle && (existingOwner == nil || existingOwner == owner) {
        self.surfaceOwners[imageId] = ErikaIOSImageSurfaceRecord(owner: owner, layer: layer)
      }
      self.stateLock.unlock()
      guard open, currentGeneration, knownHandle,
            existingOwner == nil || existingOwner == owner else {
        self.emitSurfaceFailure(
          imageId: imageId,
          viewId: viewId,
          owner: owner,
          message: knownHandle ? "image is attached to another view" : "HDR image session was not found"
        )
        return
      }

      let response = ErikaImageNativeBridge.attachSurface(
        handle: imageId,
        metalLayer: Unmanaged.passUnretained(layer).toOpaque(),
        width: metrics.width,
        height: metrics.height,
        scale: metrics.scale,
        extendedLinear: metrics.capability.eligible,
        directComposition: true,
        desiredHeadroom: metrics.capability.desiredHeadroom,
        fallbackReason: metrics.capability.fallbackReason
      )
      let rendered = bridgeSucceeded(response)
        ? ErikaImageNativeBridge.renderSurface(handle: imageId)
        : response
      if !bridgeSucceeded(rendered) {
        if bridgeSucceeded(response) {
          _ = ErikaImageNativeBridge.detachSurface(handle: imageId)
        }
        self.stateLock.lock()
        if self.surfaceOwners[imageId]?.owner == owner {
          self.surfaceOwners.removeValue(forKey: imageId)
        }
        self.stateLock.unlock()
      }
      self.emitSurfaceResponse(
        rendered,
        imageId: imageId,
        viewId: viewId,
        owner: owner,
        currentHeadroom: currentHeadroom,
        requireSurfaceOwner: bridgeSucceeded(rendered)
      )
      if bridgeSucceeded(rendered), metrics.capability.eligible {
        self.verifyCurrentHeadroom(
          imageId: imageId,
          viewId: viewId,
          owner: owner,
          attempt: 0,
          currentHeadroom: headroomProvider
        )
      }
    }
  }

  fileprivate func resizeHdrSurface(
    imageId: UInt64,
    viewId: Int64,
    generation: UInt64,
    metrics: ErikaIOSImageSurfaceMetrics,
    currentHeadroom: Float
  ) {
    let owner = ErikaIOSImageSurfaceOwner(viewId: viewId, generation: generation)
    surfaceQueue.async { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      let ownsSurface = !self.closing &&
        self.activeViewGenerations[viewId] == generation &&
        self.surfaceOwners[imageId]?.owner == owner
      self.stateLock.unlock()
      guard ownsSurface else { return }
      let resized = ErikaImageNativeBridge.resizeSurface(
        handle: imageId,
        width: metrics.width,
        height: metrics.height,
        scale: metrics.scale
      )
      let rendered = bridgeSucceeded(resized)
        ? ErikaImageNativeBridge.renderSurface(handle: imageId)
        : resized
      self.emitSurfaceResponse(
        rendered,
        imageId: imageId,
        viewId: viewId,
        owner: owner,
        currentHeadroom: currentHeadroom
      )
    }
  }

  func detachHdrSurface(
    imageId: UInt64,
    viewId: Int64,
    generation: UInt64,
    completion: (() -> Void)? = nil
  ) {
    let owner = ErikaIOSImageSurfaceOwner(viewId: viewId, generation: generation)
    surfaceQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { completion?() }
        return
      }
      self.stateLock.lock()
      let record = self.surfaceOwners[imageId]
      let ownsSurface = record?.owner == owner
      self.stateLock.unlock()
      if ownsSurface {
        _ = ErikaImageNativeBridge.detachSurface(handle: imageId)
        self.stateLock.lock()
        if self.surfaceOwners[imageId] === record {
          self.surfaceOwners.removeValue(forKey: imageId)
        }
        self.stateLock.unlock()
      }
      DispatchQueue.main.async { completion?() }
    }
  }

  func shutdown() {
    var activeOperations: [UInt64] = []
    var handles: [UInt64] = []
    var textureIds: [Int64] = []
    stateLock.lock()
    guard !closing else {
      stateLock.unlock()
      return
    }
    closing = true
    lifecycleGeneration &+= 1
    pending.forEach { $0.cancelled = true }
    pending.removeAll()
    inflight.values.forEach { $0.cancelled = true }
    activeOperations = inflight.values.map(\.nativeOperationId)
    handles = Array(hdrHandles)
    textureIds = Array(sdrTextures.keys)
    sdrTextures.removeAll()
    nativeOperationIdsByDartId.removeAll()
    hdrReservation = nil
    activeViewGenerations.removeAll()
    stateLock.unlock()
    for activeOperation in activeOperations {
      _ = ErikaImageNativeBridge.cancel(operationId: activeOperation)
    }
    DispatchQueue.main.async { [textureRegistry] in
      textureIds.forEach { textureRegistry.unregisterTexture($0) }
    }
    surfaceQueue.async { [weak self] in
      for handle in handles {
        _ = ErikaImageNativeBridge.detachSurface(handle: handle)
        _ = ErikaImageNativeBridge.destroy(handle: handle)
      }
      self?.stateLock.lock()
      self?.hdrHandles.removeAll()
      self?.surfaceOwners.removeAll()
      self?.activeHandleCount = 0
      self?.stateLock.unlock()
    }
  }

  private func enqueue(
    _ arguments: [String: Any],
    kind: ErikaIOSImageDecodeKind,
    result: @escaping FlutterResult
  ) {
    guard let dartOperationId = uint64(arguments["operationId"]), dartOperationId > 0,
          let path = arguments["path"] as? String, !path.isEmpty else {
      result(imageFlutterError(kind: erikaImageErrorInternal, message: "operationId and path are required"))
      return
    }
    let requestedWidth = integer(arguments["cacheWidth"])
    let requestedHeight = integer(arguments["cacheHeight"])
    guard requestedWidth >= 0, requestedHeight >= 0,
          requestedWidth <= Int(UInt32.max), requestedHeight <= Int(UInt32.max) else {
      result(imageFlutterError(kind: erikaImageErrorResourceLimit, message: "cache dimensions are invalid"))
      return
    }
    var rejection: FlutterError?
    stateLock.lock()
    if closing {
      rejection = imageFlutterError(kind: erikaImageErrorBusy, message: "image subsystem is closing")
    } else if pending.count >= policy.maxQueuedDecodes {
      rejection = imageFlutterError(kind: erikaImageErrorBusy, message: "image decode queue is full")
    } else if nativeOperationIdsByDartId[dartOperationId] != nil {
      rejection = imageFlutterError(kind: erikaImageErrorInternal, message: "image operation is already active")
    } else if kind == .hdr && (hdrReservation != nil || !hdrHandles.isEmpty) {
      rejection = imageFlutterError(kind: erikaImageErrorBusy, message: "another HDR image session is active")
    } else if let nativeOperationId = ErikaIOSNativeImageOperationIds.allocate() {
      let job = ErikaIOSImageDecodeJob(
        dartOperationId: dartOperationId,
        nativeOperationId: nativeOperationId,
        kind: kind,
        path: path,
        maxWidth: UInt32(requestedWidth),
        maxHeight: UInt32(requestedHeight),
        policy: policy,
        hdrSurfaceSupported: {
          guard #available(iOS 16.0, *) else { return false }
          return UIScreen.main.potentialEDRHeadroom > 1.0
        }(),
        subsystemGeneration: lifecycleGeneration,
        result: result
      )
      if kind == .hdr {
        hdrReservation = dartOperationId
      }
      nativeOperationIdsByDartId[dartOperationId] = nativeOperationId
      pending.append(job)
      startNextDecodesLocked()
    } else {
      rejection = imageFlutterError(
        kind: erikaImageErrorInternal,
        message: "native image operation id space is exhausted"
      )
    }
    stateLock.unlock()
    if let rejection {
      result(rejection)
    }
  }

  private func startNextDecodesLocked() {
    while inflight.count < policy.maxConcurrentDecodes, !pending.isEmpty, !closing {
      let job = pending.removeFirst()
      inflight[job.dartOperationId] = job
      decodeQueue.async { [weak self] in
        self?.run(job)
      }
    }
  }

  private func run(_ job: ErikaIOSImageDecodeJob) {
    if isCancelled(job) {
      finish(job)
      return
    }
    guard FileManager.default.fileExists(atPath: job.path) else {
      deliverFailure(job, kind: 4, message: "cached image file does not exist")
      finish(job)
      return
    }
    let fileSize = ((try? FileManager.default.attributesOfItem(atPath: job.path)[.size]) as? NSNumber)?.intValue ?? 0
    guard fileSize >= 0, fileSize <= job.policy.maxEncodedBytes else {
      deliverFailure(
        job,
        kind: erikaImageErrorResourceLimit,
        message: "encoded image exceeds the supported limit"
      )
      finish(job)
      return
    }
    if isCancelled(job) {
      finish(job)
      return
    }
    let decoded = ErikaImageNativeBridge.decode(
      operationId: job.nativeOperationId,
      path: job.path,
      maxWidth: job.maxWidth,
      maxHeight: job.maxHeight,
      maxEncodedBytes: UInt64(job.policy.maxEncodedBytes),
      maxSourcePixels: UInt64(job.policy.maxSourcePixels),
      maxOutputPixels: UInt64(job.policy.maxOutputPixels),
      maxPacketsBeforeFrame: UInt32(job.policy.maxPacketsBeforeFrame),
      decodeTimeoutMillis: UInt64(job.policy.decodeTimeoutMillis)
    )
    guard bridgeSucceeded(decoded),
          let value = bridgeValue(decoded),
          let imageId = uint64(value["imageId"]), imageId > 0 else {
      if !isCancelled(job) {
        deliverFailure(job, response: decoded)
      }
      finish(job)
      return
    }

    stateLock.lock()
    activeHandleCount += 1
    stateLock.unlock()
    var transfersHandle = false
    defer {
      if !transfersHandle {
        _ = ErikaImageNativeBridge.destroy(handle: imageId)
        stateLock.lock()
        activeHandleCount = max(0, activeHandleCount - 1)
        stateLock.unlock()
      }
      finish(job)
    }
    if isCancelled(job) {
      return
    }

    if job.kind == .automatic,
       integer(value["sourceDynamicRange"]) >= 2,
       job.hdrSurfaceSupported {
      stateLock.lock()
      let canTransfer = !closing && !job.cancelled &&
        hdrReservation == nil && hdrHandles.isEmpty
      if canTransfer {
        hdrHandles.insert(imageId)
        decodeCount &+= 1
        transfersHandle = true
      }
      stateLock.unlock()
      if canTransfer {
        var response = value
        response["presentation"] = "hdr"
        deliverSuccess(job, value: response)
        return
      }
    }

    switch job.kind {
    case .automatic, .sdr:
      let rendered = ErikaImageNativeBridge.renderSdr(
        handle: imageId,
        maxWidth: job.maxWidth,
        maxHeight: job.maxHeight
      )
      guard bridgeSucceeded(rendered), let rgbaValue = bridgeValue(rendered),
            let data = rgbaValue["rgba"] as? Data else {
        if !isCancelled(job) {
          deliverFailure(job, response: rendered)
        }
        return
      }
      let (maxRgbaBytes, overflow) = job.policy.maxOutputPixels.multipliedReportingOverflow(by: 4)
      guard !overflow, data.count <= maxRgbaBytes else {
        deliverFailure(job, kind: erikaImageErrorResourceLimit, message: "decoded image exceeds the RGBA limit")
        return
      }
      if isCancelled(job) { return }
      let outputWidth = integer(rgbaValue["width"])
      let outputHeight = integer(rgbaValue["height"])
      let outputRowBytes = integer(rgbaValue["rowBytes"])
      guard let texture = ErikaIOSSdrTexture(
        rgba: data,
        width: outputWidth,
        height: outputHeight,
        sourceRowBytes: outputRowBytes
      ) else {
        deliverFailure(job, kind: erikaImageErrorRenderer, message: "unable to create the SDR image texture")
        return
      }
      var textureId: Int64 = -1
      DispatchQueue.main.sync {
        textureId = textureRegistry.register(texture)
      }
      guard textureId >= 0 else {
        deliverFailure(job, kind: erikaImageErrorRenderer, message: "Flutter rejected the SDR image texture")
        return
      }
      stateLock.lock()
      let canTransfer = !closing && !job.cancelled &&
        job.subsystemGeneration == lifecycleGeneration
      if canTransfer {
        sdrTextures[textureId] = texture
        decodeCount &+= 1
      }
      stateLock.unlock()
      guard canTransfer else {
        DispatchQueue.main.async { [textureRegistry] in
          textureRegistry.unregisterTexture(textureId)
        }
        return
      }
      var response = value
      response["sourceWidth"] = value["width"]
      response["sourceHeight"] = value["height"]
      response["width"] = outputWidth
      response["height"] = outputHeight
      response["textureId"] = textureId
      response["presentation"] = "sdr"
      DispatchQueue.main.async { [textureRegistry] in
        textureRegistry.textureFrameAvailable(textureId)
      }
      deliverSuccess(job, value: response)
    case .hdr:
      stateLock.lock()
      let canTransfer = !closing && !job.cancelled &&
        hdrReservation == job.dartOperationId && hdrHandles.isEmpty
      if canTransfer {
        hdrReservation = nil
        hdrHandles.insert(imageId)
        decodeCount &+= 1
        transfersHandle = true
      }
      stateLock.unlock()
      if canTransfer {
        var response = value
        response["presentation"] = "hdr"
        deliverSuccess(job, value: response)
      }
    }
  }

  private func finish(_ job: ErikaIOSImageDecodeJob) {
    stateLock.lock()
    if hdrReservation == job.dartOperationId {
      hdrReservation = nil
    }
    if nativeOperationIdsByDartId[job.dartOperationId] == job.nativeOperationId {
      nativeOperationIdsByDartId.removeValue(forKey: job.dartOperationId)
    }
    if inflight[job.dartOperationId] === job {
      inflight.removeValue(forKey: job.dartOperationId)
    }
    startNextDecodesLocked()
    stateLock.unlock()
  }

  private func deliverSuccess(_ job: ErikaIOSImageDecodeJob, value: [String: Any]) {
    guard markDelivered(job) else { return }
    DispatchQueue.main.async { [weak self] in
      guard self?.mayDeliver(job) == true else { return }
      job.result(value)
    }
  }

  private func deliverFailure(_ job: ErikaIOSImageDecodeJob, response: [String: Any]) {
    let kind = integer(response["kind"])
    let message = response["error"] as? String ?? "Erika image operation failed"
    deliverFailure(job, kind: kind == 0 ? erikaImageErrorInternal : kind, message: message)
  }

  private func deliverFailure(_ job: ErikaIOSImageDecodeJob, kind: Int, message: String) {
    guard markDelivered(job) else { return }
    DispatchQueue.main.async { [weak self] in
      guard self?.mayDeliver(job) == true else { return }
      job.result(imageFlutterError(kind: kind, message: message))
    }
  }

  private func markDelivered(_ job: ErikaIOSImageDecodeJob) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !job.delivered, !closing else { return false }
    job.delivered = true
    return true
  }

  private func mayDeliver(_ job: ErikaIOSImageDecodeJob) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !closing && job.subsystemGeneration == lifecycleGeneration
  }

  private func isGenerationActive(_ generation: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !closing && lifecycleGeneration == generation
  }

  private func isCancelled(_ job: ErikaIOSImageDecodeJob) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return job.cancelled || closing || job.subsystemGeneration != lifecycleGeneration
  }

  private func verifyCurrentHeadroom(
    imageId: UInt64,
    viewId: Int64,
    owner: ErikaIOSImageSurfaceOwner,
    attempt: Int,
    currentHeadroom: @escaping () -> Float
  ) {
    let delays: [TimeInterval] = [0.04, 0.12, 0.24, 0.5, 1.0]
    guard attempt < delays.count else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
      guard let self, self.isSurfaceCurrent(imageId: imageId, owner: owner) else { return }
      // UIKit and UIScreen state are read only on the main thread.
      let headroom = currentHeadroom()
      if headroom <= 1.0 {
        self.verifyCurrentHeadroom(
          imageId: imageId,
          viewId: viewId,
          owner: owner,
          attempt: attempt + 1,
          currentHeadroom: currentHeadroom
        )
        return
      }
      self.surfaceQueue.async { [weak self] in
        guard let self, self.isSurfaceCurrent(imageId: imageId, owner: owner) else { return }
        let rendered = ErikaImageNativeBridge.renderSurface(handle: imageId)
        self.emitSurfaceResponse(
          rendered,
          imageId: imageId,
          viewId: viewId,
          owner: owner,
          currentHeadroom: headroom
        )
      }
    }
  }

  private func emitSurfaceFailure(
    imageId: UInt64,
    viewId: Int64,
    owner: ErikaIOSImageSurfaceOwner,
    message: String
  ) {
    emitSurfaceResponse(
      ["ok": false, "kind": erikaImageErrorRenderer, "error": message],
      imageId: imageId,
      viewId: viewId,
      owner: owner,
      currentHeadroom: 1.0,
      requireSurfaceOwner: false
    )
  }

  private func emitSurfaceResponse(
    _ response: [String: Any],
    imageId: UInt64,
    viewId: Int64,
    owner: ErikaIOSImageSurfaceOwner,
    currentHeadroom: Float,
    requireSurfaceOwner: Bool = true
  ) {
    var value = bridgeValue(response) ?? [:]
    if value["hdrOutputConfirmed"] as? Bool == true && currentHeadroom <= 1.0 {
      value["hdrOutputConfirmed"] = false
    }
    let event: [String: Any] = [
      "viewId": viewId,
      "imageId": Int64(bitPattern: imageId),
      "ok": bridgeSucceeded(response),
      "error": response["error"] as Any,
      "value": value,
    ]
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let current = requireSurfaceOwner
        ? self.isSurfaceCurrent(imageId: imageId, owner: owner)
        : self.isViewCurrent(owner)
      guard current else { return }
      self.channel.invokeMethod("imageSurfaceEvent", arguments: event)
    }
  }

  private func isSurfaceCurrent(
    imageId: UInt64,
    owner: ErikaIOSImageSurfaceOwner
  ) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !closing &&
      activeViewGenerations[owner.viewId] == owner.generation &&
      surfaceOwners[imageId]?.owner == owner
  }

  private func isViewCurrent(_ owner: ErikaIOSImageSurfaceOwner) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !closing && activeViewGenerations[owner.viewId] == owner.generation
  }
}

final class ErikaIOSHdrImageViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var subsystem: ErikaIOSImageSubsystem?

  init(subsystem: ErikaIOSImageSubsystem) {
    self.subsystem = subsystem
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let values = args as? [String: Any] ?? [:]
    let imageId = uint64(values["imageId"]) ?? 0
    return ErikaIOSHdrImagePlatformView(
      frame: frame,
      viewId: viewId,
      imageId: imageId,
      subsystem: subsystem
    )
  }
}

private final class ErikaIOSHdrImagePlatformView: NSObject, FlutterPlatformView {
  private let imageView: ErikaIOSHdrImageUIView

  init(
    frame: CGRect,
    viewId: Int64,
    imageId: UInt64,
    subsystem: ErikaIOSImageSubsystem?
  ) {
    imageView = ErikaIOSHdrImageUIView(
      frame: frame,
      viewId: viewId,
      imageId: imageId,
      subsystem: subsystem
    )
    super.init()
  }

  func view() -> UIView { imageView }
}

private final class ErikaIOSHdrImageUIView: UIView {
  private let viewId: Int64
  private let imageId: UInt64
  private weak var subsystem: ErikaIOSImageSubsystem?
  private var disposed = false
  private var attached = false
  private var generation: UInt64 = 0
  private var lastMetrics: ErikaIOSImageSurfaceMetrics?

  override class var layerClass: AnyClass { CAMetalLayer.self }
  private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

  init(
    frame: CGRect,
    viewId: Int64,
    imageId: UInt64,
    subsystem: ErikaIOSImageSubsystem?
  ) {
    self.viewId = viewId
    self.imageId = imageId
    self.subsystem = subsystem
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    subsystem?.registerHdrView(viewId)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      detach()
    } else {
      updateSurface()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateSurface()
  }

  private func updateSurface() {
    guard !disposed, window != nil, bounds.width > 0, bounds.height > 0,
          imageId > 0, let subsystem else { return }
    let metrics = configureLayer()
    if !attached || lastMetrics?.capability != metrics.capability {
      if attached {
        detach()
      }
      attach(with: metrics)
      return
    }
    if lastMetrics != metrics {
      lastMetrics = metrics
      let activeGeneration = generation
      subsystem.resizeHdrSurface(
        imageId: imageId,
        viewId: viewId,
        generation: activeGeneration,
        metrics: metrics,
        currentHeadroom: metrics.currentHeadroom
      )
    }
  }

  private func attach(with metrics: ErikaIOSImageSurfaceMetrics) {
    guard !disposed, window != nil, let subsystem else { return }
    generation &+= 1
    let activeGeneration = generation
    attached = true
    lastMetrics = metrics
    subsystem.activateHdrView(viewId, generation: activeGeneration)
    subsystem.attachHdrSurface(
      imageId: imageId,
      viewId: viewId,
      generation: activeGeneration,
      layer: metalLayer,
      metrics: metrics,
      currentHeadroom: metrics.currentHeadroom,
      headroomProvider: { [weak self] in self?.currentEdrHeadroom() ?? 1.0 }
    )
  }

  private func detach() {
    guard attached, let subsystem else { return }
    let activeGeneration = generation
    attached = false
    lastMetrics = nil
    subsystem.deactivateHdrView(viewId, generation: activeGeneration)
    subsystem.detachHdrSurface(
      imageId: imageId,
      viewId: viewId,
      generation: activeGeneration
    )
  }

  private func configureLayer() -> ErikaIOSImageSurfaceMetrics {
    let screen = window?.screen ?? UIScreen.main
    let scale = max(1.0, screen.scale)
    let currentHeadroom = currentEdrHeadroom()
    let potentialHeadroom: Float
    if #available(iOS 16.0, *) {
      potentialHeadroom = Float(screen.potentialEDRHeadroom)
    } else {
      potentialHeadroom = 1.0
    }
    let eligible = potentialHeadroom > 1.0
    let desiredHeadroom = max(1.0, max(currentHeadroom, potentialHeadroom))
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(
      width: max(1.0, bounds.width * scale),
      height: max(1.0, bounds.height * scale)
    )
    metalLayer.framebufferOnly = true
    metalLayer.isOpaque = true
    if eligible {
      metalLayer.pixelFormat = .rgba16Float
      metalLayer.contentsFormat = .RGBA16Float
      // The renderer writes BT.709/extended-sRGB values. Labelling those
      // values as Display P3 would make Core Animation reinterpret the same
      // components in a wider gamut and visibly shift colour.
      metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    } else {
      metalLayer.pixelFormat = .bgra8Unorm
      metalLayer.contentsFormat = .RGBA8Uint
      metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }
    if #available(iOS 16.0, *) {
      metalLayer.wantsExtendedDynamicRangeContent = eligible
    }
    return ErikaIOSImageSurfaceMetrics(
      width: UInt32(max(1.0, metalLayer.drawableSize.width).rounded(.up)),
      height: UInt32(max(1.0, metalLayer.drawableSize.height).rounded(.up)),
      scale: Double(scale),
      currentHeadroom: currentHeadroom,
      capability: ErikaIOSEdrCapability(
        eligible: eligible,
        desiredHeadroom: desiredHeadroom,
        fallbackReason: eligible ? 0 : Int32(erikaDisplayHdrUnsupported)
      )
    )
  }

  private func currentEdrHeadroom() -> Float {
    guard #available(iOS 16.0, *) else { return 1.0 }
    return Float(window?.screen.currentEDRHeadroom ?? UIScreen.main.currentEDRHeadroom)
  }

  func disposeImageView() {
    guard !disposed else { return }
    disposed = true
    let activeGeneration = generation
    let id = viewId
    let owner = subsystem
    attached = false
    lastMetrics = nil
    owner?.deactivateHdrView(id, generation: activeGeneration)
    owner?.detachHdrSurface(
      imageId: imageId,
      viewId: id,
      generation: activeGeneration
    ) { [weak owner] in
      owner?.unregisterHdrView(id)
    }
  }

  deinit {
    disposeImageView()
  }
}

private func bridgeSucceeded(_ response: [String: Any]) -> Bool {
  response["ok"] as? Bool == true
}

private func bridgeValue(_ response: [String: Any]) -> [String: Any]? {
  response["value"] as? [String: Any]
}

private func imageFlutterError(
  from response: [String: Any],
  defaultKind: Int
) -> FlutterError {
  let kind = integer(response["kind"])
  return imageFlutterError(
    kind: kind == 0 ? defaultKind : kind,
    message: response["error"] as? String ?? "Erika image operation failed"
  )
}

private func imageFlutterError(kind: Int, message: String) -> FlutterError {
  FlutterError(
    code: "ERIKA_IMAGE_ERROR",
    message: message,
    details: ["kind": kind]
  )
}

private func integer(_ value: Any?) -> Int {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) ?? 0 }
  return 0
}

private func uint64(_ value: Any?) -> UInt64? {
  if let value = value as? UInt64 { return value }
  if let value = value as? Int, value >= 0 { return UInt64(value) }
  if let value = value as? NSNumber { return value.uint64Value }
  if let value = value as? String { return UInt64(value) }
  return nil
}

private func int64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  if let value = value as? String { return Int64(value) }
  return nil
}
