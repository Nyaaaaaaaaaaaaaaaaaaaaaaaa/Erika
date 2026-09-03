#include "include/erika_ohos_image.h"

#include <native_window/external_window.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "erika.h"
#include "erika_harmony_next_surface.h"

namespace {

constexpr size_t kMaxQueuedImageDecodes = 8;
constexpr uint64_t kMaxEncodedBytes = 128ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxSourcePixels = 32ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxSdrOutputPixels = 32ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxActiveHdrImages = 1;

enum class ImageWorkStage : int32_t {
  kQueued = 0,
  kExecuting = 1,
  kNativeFinished = 2,
  kCompleted = 3,
};

struct OhosImageSession {
  explicit OhosImageSession(ErikaImageHandle image_handle,
                            ErikaImageMetadata image_metadata,
                            uint64_t image_runtime_generation)
      : handle(image_handle), metadata(image_metadata),
        runtime_generation(image_runtime_generation) {}

  std::mutex mutex;
  ErikaImageHandle handle = 0;
  ErikaImageMetadata metadata = {};
  OHNativeWindow *window = nullptr;
  ErikaHarmonyNextSurfaceState surface_state;
  uint64_t runtime_generation = 0;
  uint64_t surface_generation = 0;
  std::atomic<bool> closing{false};
  bool hdr_reservation_held = true;
};

struct ImageDecodeWork {
  napi_env env = nullptr;
  napi_async_work async_work = nullptr;
  napi_deferred deferred = nullptr;
  uint64_t runtime_generation = 0;
  uint64_t client_operation_id = 0;
  uint64_t native_operation_id = 0;
  std::string path;
  uint32_t max_width = 0;
  uint32_t max_height = 0;
  bool hdr = false;
  bool hdr_reservation_held = false;
  bool scheduled = false;
  std::atomic<bool> cancelled{false};
  std::atomic<ImageWorkStage> stage{ImageWorkStage::kQueued};
  std::mutex native_state_mutex;
  bool native_decode_active = false;
  ErikaStatus status = ErikaStatus_Ok;
  ErikaImageErrorKind error_kind = ErikaImageErrorKind_None;
  std::string error;
  ErikaImageHandle handle = 0;
  ErikaImageMetadata metadata = {};
  uint32_t output_width = 0;
  uint32_t output_height = 0;
  uint32_t row_bytes = 0;
  ErikaImageRgba rgba = {};
};

enum class ImageSurfaceOperation {
  kAttach,
  kResize,
  kRender,
  kDetach,
  kDestroy,
};

struct ImageSurfaceWork {
  napi_env env = nullptr;
  napi_async_work async_work = nullptr;
  napi_deferred deferred = nullptr;
  uint64_t runtime_generation = 0;
  uint64_t image_id = 0;
  uint64_t surface_generation = 0;
  uint64_t surface_id = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  double scale = 1.0;
  ImageSurfaceOperation operation = ImageSurfaceOperation::kRender;
  std::shared_ptr<OhosImageSession> image;
  ErikaStatus status = ErikaStatus_Ok;
  ErikaImageErrorKind error_kind = ErikaImageErrorKind_None;
  std::string error;
  ErikaOutputStatus output = {};
  ErikaDynamicRangeStatus dynamic_range = {};
  bool has_output_status = false;
};

struct ImageEnvironmentCleanup {
  uint64_t runtime_generation = 0;
  std::vector<std::shared_ptr<OhosImageSession>> orphaned_sessions;
};

std::mutex g_image_sessions_mutex;
std::unordered_map<uint64_t, std::shared_ptr<OhosImageSession>>
    g_image_sessions;

std::mutex g_image_jobs_mutex;
std::unordered_map<uint64_t, ImageDecodeWork *> g_image_jobs;
std::deque<ImageDecodeWork *> g_decode_queue;
ImageDecodeWork *g_active_decode_work = nullptr;
std::mutex g_surface_jobs_mutex;
std::deque<ImageSurfaceWork *> g_surface_queue;
ImageSurfaceWork *g_active_surface_work = nullptr;
std::atomic<uint64_t> g_surface_work_count{0};

std::atomic<uint64_t> g_current_runtime_generation{0};
std::atomic<uint64_t> g_closing_runtime_generation{0};
std::mutex g_runtime_owner_mutex;
uint64_t g_registered_runtime_generation = 0;
std::mutex g_async_counts_mutex;
std::condition_variable g_async_counts_changed;
std::unordered_map<uint64_t, size_t> g_async_counts;

std::atomic<uint64_t> g_queued_decodes{0};
std::atomic<uint64_t> g_inflight_decodes{0};
std::atomic<uint64_t> g_decode_count{0};
std::atomic<uint64_t> g_cancelled_queued{0};
std::atomic<uint64_t> g_active_handles{0};
std::atomic<uint64_t> g_hdr_reservations{0};
std::atomic<uint64_t> g_next_native_operation_id{1};

uint64_t NextNativeOperationId() {
  // ArkTS ids restart with each environment, while C cancellation state is
  // process-global. A process-unique token prevents a retiring environment's
  // cancellation tombstone from affecting the next environment.
  uint64_t operation_id =
      g_next_native_operation_id.fetch_add(1, std::memory_order_relaxed);
  if (operation_id == 0) {
    operation_id =
        g_next_native_operation_id.fetch_add(1, std::memory_order_relaxed);
  }
  return operation_id;
}

bool TryReserveHdrImage() {
  uint64_t expected = 0;
  return g_hdr_reservations.compare_exchange_strong(
      expected, kMaxActiveHdrImages, std::memory_order_acq_rel,
      std::memory_order_acquire);
}

void ReleaseHdrReservation(bool *held) {
  if (held == nullptr || !*held) {
    return;
  }
  *held = false;
  g_hdr_reservations.fetch_sub(1, std::memory_order_acq_rel);
}

bool RuntimeIsActive(uint64_t generation) {
  return generation != 0 &&
         g_current_runtime_generation.load(std::memory_order_acquire) ==
             generation &&
         g_closing_runtime_generation.load(std::memory_order_acquire) !=
             generation;
}

void AddAsyncWork(uint64_t generation) {
  std::lock_guard<std::mutex> lock(g_async_counts_mutex);
  g_async_counts[generation] += 1;
}

void FinishAsyncWork(uint64_t generation) {
  {
    std::lock_guard<std::mutex> lock(g_async_counts_mutex);
    const auto found = g_async_counts.find(generation);
    if (found != g_async_counts.end()) {
      if (found->second <= 1) {
        g_async_counts.erase(found);
      } else {
        found->second -= 1;
      }
    }
  }
  g_async_counts_changed.notify_all();
}

napi_value Undefined(napi_env env) {
  napi_value value = nullptr;
  napi_get_undefined(env, &value);
  return value;
}

napi_value Boolean(napi_env env, bool value) {
  napi_value result = nullptr;
  napi_get_boolean(env, value, &result);
  return result;
}

napi_value Int32(napi_env env, int32_t value) {
  napi_value result = nullptr;
  napi_create_int32(env, value, &result);
  return result;
}

napi_value Uint32(napi_env env, uint32_t value) {
  napi_value result = nullptr;
  napi_create_uint32(env, value, &result);
  return result;
}

napi_value Uint64Number(napi_env env, uint64_t value) {
  napi_value result = nullptr;
  napi_create_double(env, static_cast<double>(value), &result);
  return result;
}

napi_value Uint64BigInt(napi_env env, uint64_t value) {
  napi_value result = nullptr;
  napi_create_bigint_uint64(env, value, &result);
  return result;
}

napi_value Double(napi_env env, double value) {
  napi_value result = nullptr;
  napi_create_double(env, value, &result);
  return result;
}

napi_value String(napi_env env, const std::string &value) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

bool Set(napi_env env, napi_value object, const char *name, napi_value value) {
  return object != nullptr && value != nullptr &&
         napi_set_named_property(env, object, name, value) == napi_ok;
}

uint64_t GetUint64(napi_env env, napi_value value) {
  uint64_t result = 0;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, value, &result, &lossless) != napi_ok ||
      !lossless) {
    return 0;
  }
  return result;
}

uint32_t GetUint32(napi_env env, napi_value value) {
  uint32_t result = 0;
  napi_get_value_uint32(env, value, &result);
  return result;
}

double GetDouble(napi_env env, napi_value value) {
  double result = 0.0;
  napi_get_value_double(env, value, &result);
  return result;
}

std::string GetString(napi_env env, napi_value value) {
  size_t size = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) {
    return {};
  }
  std::string result(size, '\0');
  if (size == 0) {
    return result;
  }
  size_t written = 0;
  result.resize(size + 1);
  if (napi_get_value_string_utf8(env, value, result.data(), result.size(),
                                 &written) != napi_ok) {
    return {};
  }
  result.resize(written);
  return result;
}

std::string LastErrorMessage() {
  char *message = erika_last_error_message();
  const std::string copy =
      message == nullptr ? "Erika image operation failed" : message;
  erika_string_free(message);
  return copy;
}

napi_value ErrorValue(napi_env env, ErikaImageErrorKind kind,
                      const std::string &message) {
  napi_value text = String(env, message);
  napi_value error = nullptr;
  napi_create_error(env, nullptr, text, &error);
  Set(env, error, "kind", Int32(env, static_cast<int32_t>(kind)));
  return error;
}

napi_value Response(napi_env env, ErikaStatus status,
                    napi_value value = nullptr,
                    ErikaImageErrorKind error_kind = ErikaImageErrorKind_None,
                    const std::string &error = {}) {
  napi_value response = nullptr;
  napi_create_object(env, &response);
  Set(env, response, "ok", Boolean(env, status == ErikaStatus_Ok));
  Set(env, response, "status", Int32(env, static_cast<int32_t>(status)));
  if (value != nullptr) {
    Set(env, response, "value", value);
  }
  if (status != ErikaStatus_Ok) {
    Set(env, response, "kind", Int32(env, static_cast<int32_t>(error_kind)));
    Set(env, response, "error", String(env, error));
  }
  return response;
}

bool MetadataValue(napi_env env, const ErikaImageMetadata &metadata,
                   napi_value *result) {
  if (result == nullptr) {
    return false;
  }
  *result = nullptr;
  napi_value value = nullptr;
  if (napi_create_object(env, &value) != napi_ok || value == nullptr ||
      !Set(env, value, "width", Uint32(env, metadata.width)) ||
      !Set(env, value, "height", Uint32(env, metadata.height)) ||
      !Set(env, value, "bitDepth", Uint32(env, metadata.bit_depth)) ||
      !Set(env, value, "primaries", Uint32(env, metadata.primaries)) ||
      !Set(env, value, "transfer", Uint32(env, metadata.transfer)) ||
      !Set(env, value, "matrix", Uint32(env, metadata.matrix)) ||
      !Set(env, value, "colorRange", Uint32(env, metadata.color_range)) ||
      !Set(env, value, "sourceDynamicRange",
           Int32(env, metadata.source_dynamic_range)) ||
      !Set(env, value, "decodeBackend", Int32(env, metadata.decode_backend))) {
    return false;
  }
  *result = value;
  return true;
}

napi_value OutputStatusValue(napi_env env, const ErikaOutputStatus &output,
                             const ErikaDynamicRangeStatus &dynamic_range) {
  napi_value value = nullptr;
  napi_create_object(env, &value);
  Set(env, value, "requestedMode", Int32(env, output.requested_mode));
  Set(env, value, "activeEncoding", Int32(env, output.active_encoding));
  Set(env, value, "surfaceFormat", Int32(env, output.surface_format));
  Set(env, value, "nativeDataSpace", Int32(env, output.native_data_space));
  Set(env, value, "requestedHeadroom", Double(env, output.requested_headroom));
  Set(env, value, "activeHeadroom", Double(env, output.active_headroom));
  Set(env, value, "activeHeadroomKnown",
      Boolean(env, output.active_headroom_known));
  Set(env, value, "extendedLinearActive",
      Boolean(env, output.extended_linear_active));
  Set(env, value, "fallbackReason", Int32(env, output.fallback_reason));
  Set(env, value, "fallbackCount", Uint64Number(env, output.fallback_count));
  Set(env, value, "dataSpaceFailures",
      Uint64Number(env, output.data_space_failures));
  Set(env, value, "headroomUpdates",
      Uint64Number(env, output.headroom_updates));
  Set(env, value, "extendedLinearFrames",
      Uint64Number(env, output.extended_linear_frames));
  Set(env, value, "sourceDynamicRange",
      Int32(env, dynamic_range.source_dynamic_range));
  Set(env, value, "activeDynamicRange",
      Int32(env, dynamic_range.active_dynamic_range));
  Set(env, value, "hdrOutputConfirmed",
      Boolean(env, dynamic_range.hdr_output_confirmed));
  return value;
}

std::shared_ptr<OhosImageSession> FindImage(uint64_t image_id) {
  std::lock_guard<std::mutex> lock(g_image_sessions_mutex);
  const auto found = g_image_sessions.find(image_id);
  return found == g_image_sessions.end() ? nullptr : found->second;
}

ErikaStatus DetachWindowLocked(OhosImageSession &image,
                               ErikaImageErrorKind *error_kind,
                               std::string *error) {
  if (image.window == nullptr) {
    return ErikaStatus_Ok;
  }
  const ErikaStatus status = erika_image_detach_surface(image.handle);
  if (status != ErikaStatus_Ok) {
    if (error_kind != nullptr) {
      *error_kind = erika_image_last_error_kind();
    }
    if (error != nullptr) {
      *error = LastErrorMessage();
    }
    return status;
  }
  OH_NativeWindow_DestroyNativeWindow(image.window);
  image.window = nullptr;
  image.surface_state = {};
  return ErikaStatus_Ok;
}

void SetWorkError(ImageDecodeWork *work, ErikaStatus status,
                  ErikaImageErrorKind kind, std::string error) {
  work->status = status;
  work->error_kind = kind;
  work->error = std::move(error);
}

void SetCancelled(ImageDecodeWork *work) {
  SetWorkError(work, ErikaStatus_PlayerError, ErikaImageErrorKind_Cancelled,
               "Erika static image decode was cancelled");
}

void ExecuteImageDecode(napi_env, void *data) {
  auto *work = static_cast<ImageDecodeWork *>(data);
  ImageWorkStage expected = ImageWorkStage::kQueued;
  if (!work->stage.compare_exchange_strong(expected,
                                           ImageWorkStage::kExecuting)) {
    return;
  }
  g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);

  if (work->cancelled.load(std::memory_order_acquire)) {
    SetCancelled(work);
    work->stage.store(ImageWorkStage::kNativeFinished,
                      std::memory_order_release);
    return;
  }

  g_inflight_decodes.fetch_add(1, std::memory_order_relaxed);
  {
    std::lock_guard<std::mutex> lock(work->native_state_mutex);
    if (work->cancelled.load(std::memory_order_acquire)) {
      SetCancelled(work);
    } else {
      work->native_decode_active = true;
    }
  }

  if (work->status == ErikaStatus_Ok) {
    ErikaImageHandle handle = 0;
    const ErikaStatus status = erika_image_decode_uri_sized(
        work->native_operation_id, work->path.c_str(), nullptr,
        work->max_width, work->max_height, &handle);
    {
      std::lock_guard<std::mutex> lock(work->native_state_mutex);
      work->native_decode_active = false;
    }
    work->handle = handle;
    if (handle != 0) {
      g_active_handles.fetch_add(1, std::memory_order_relaxed);
    }
    if (status != ErikaStatus_Ok) {
      SetWorkError(work, status, erika_image_last_error_kind(),
                   LastErrorMessage());
    }
  }

  if (work->status == ErikaStatus_Ok &&
      work->cancelled.load(std::memory_order_acquire)) {
    SetCancelled(work);
  }

  if (work->status == ErikaStatus_Ok) {
    const ErikaStatus metadata_status =
        erika_image_get_metadata(work->handle, &work->metadata);
    if (metadata_status != ErikaStatus_Ok) {
      SetWorkError(work, metadata_status, erika_image_last_error_kind(),
                   LastErrorMessage());
    }
  }

  if (work->status == ErikaStatus_Ok && !work->hdr) {
    ErikaImageRgba rgba = {};
    const ErikaStatus rgba_status = erika_image_render_sdr_rgba(
        work->handle, work->max_width, work->max_height, &rgba);
    if (rgba_status == ErikaStatus_Ok && rgba.data != nullptr) {
      work->output_width = rgba.layout.width;
      work->output_height = rgba.layout.height;
      work->row_bytes = rgba.layout.row_bytes;
      work->rgba = rgba;
    } else {
      const ErikaImageErrorKind error_kind = erika_image_last_error_kind();
      const std::string error = LastErrorMessage();
      erika_image_rgba_free(&rgba);
      SetWorkError(work, rgba_status, error_kind, error);
    }
  }

  if ((!work->hdr || work->status != ErikaStatus_Ok) && work->handle != 0) {
    erika_image_destroy(work->handle);
    work->handle = 0;
    g_active_handles.fetch_sub(1, std::memory_order_relaxed);
  }
  if (work->status == ErikaStatus_Ok) {
    g_decode_count.fetch_add(1, std::memory_order_relaxed);
  }
  g_inflight_decodes.fetch_sub(1, std::memory_order_relaxed);
  work->stage.store(ImageWorkStage::kNativeFinished, std::memory_order_release);
}

void QueueNextImageDecode();

void CompleteImageDecode(napi_env completion_env, napi_status async_status,
                         void *data) {
  auto *work = static_cast<ImageDecodeWork *>(data);
  // The callback environment is contractually the same one, but keeping all
  // completion and teardown calls on the captured owner makes that invariant
  // explicit and prevents future cross-runtime queue changes from guessing.
  (void)completion_env;
  napi_env env = work->env;
  const ImageWorkStage previous = work->stage.exchange(
      ImageWorkStage::kCompleted, std::memory_order_acq_rel);
  if (previous == ImageWorkStage::kQueued) {
    g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);
  }
  {
    std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
    const auto found = g_image_jobs.find(work->client_operation_id);
    if (found != g_image_jobs.end() && found->second == work) {
      g_image_jobs.erase(found);
    }
    if (g_active_decode_work == work) {
      g_active_decode_work = nullptr;
    }
  }

  const bool cancelled = async_status == napi_cancelled ||
                         work->cancelled.load(std::memory_order_acquire);
  if (cancelled && work->status == ErikaStatus_Ok) {
    SetCancelled(work);
  }

  const bool runtime_active = RuntimeIsActive(work->runtime_generation);
  napi_value value = nullptr;
  if (runtime_active && async_status == napi_ok &&
      work->status == ErikaStatus_Ok && !cancelled) {
    napi_value metadata = nullptr;
    if (napi_create_object(env, &value) != napi_ok || value == nullptr ||
        !MetadataValue(env, work->metadata, &metadata) ||
        !Set(env, value, "metadata", metadata)) {
      value = nullptr;
      SetWorkError(work, ErikaStatus_PlayerError,
                   ErikaImageErrorKind_ResourceLimit,
                   "Unable to allocate the ArkTS image response");
    } else if (work->hdr) {
      const uint64_t image_id = work->handle;
      napi_value image_id_value = Uint64BigInt(env, image_id);
      if (!Set(env, value, "imageId", image_id_value)) {
        value = nullptr;
        SetWorkError(work, ErikaStatus_PlayerError,
                     ErikaImageErrorKind_ResourceLimit,
                     "Unable to allocate the ArkTS HDR image response");
      } else {
        auto session = std::make_shared<OhosImageSession>(
            work->handle, work->metadata, work->runtime_generation);
        bool inserted = false;
        {
          std::lock_guard<std::mutex> lock(g_image_sessions_mutex);
          inserted =
              g_image_sessions.emplace(image_id, std::move(session)).second;
        }
        if (inserted) {
          // The one HDR reservation moves from this decode job to the retained
          // image session. It is released only by explicit/session cleanup.
          work->hdr_reservation_held = false;
          work->handle = 0;
        } else {
          value = nullptr;
          SetWorkError(work, ErikaStatus_PlayerError,
                       ErikaImageErrorKind_Internal,
                       "HDR image handle is already registered");
        }
      }
    } else {
      napi_value array_buffer = nullptr;
      void *bytes = nullptr;
      const napi_status buffer_status = napi_create_arraybuffer(
          env, work->rgba.layout.byte_len, &bytes, &array_buffer);
      if (buffer_status == napi_ok &&
          (bytes != nullptr || work->rgba.layout.byte_len == 0)) {
        if (work->rgba.layout.byte_len != 0) {
          std::memcpy(bytes, work->rgba.data, work->rgba.layout.byte_len);
        }
        napi_value typed_array = nullptr;
        if (napi_create_typedarray(env, napi_uint8_array,
                                   work->rgba.layout.byte_len,
                                   array_buffer, 0, &typed_array) == napi_ok) {
          if (!Set(env, value, "rgba", typed_array) ||
              !Set(env, value, "width", Uint32(env, work->output_width)) ||
              !Set(env, value, "height", Uint32(env, work->output_height)) ||
              !Set(env, value, "rowBytes", Uint32(env, work->row_bytes))) {
            value = nullptr;
          }
        } else {
          value = nullptr;
        }
      } else {
        value = nullptr;
      }
      if (value == nullptr) {
        SetWorkError(work, ErikaStatus_PlayerError,
                     ErikaImageErrorKind_ResourceLimit,
                     "Unable to allocate the ArkTS SDR image buffer");
      }
    }
  }

  if (runtime_active && work->status == ErikaStatus_Ok && value != nullptr &&
      !cancelled) {
    napi_resolve_deferred(env, work->deferred, value);
  } else if (runtime_active) {
    if (work->status == ErikaStatus_Ok) {
      SetCancelled(work);
    }
    napi_reject_deferred(env, work->deferred,
                         ErrorValue(env, work->error_kind, work->error));
  }

  if (work->handle != 0) {
    erika_image_destroy(work->handle);
    g_active_handles.fetch_sub(1, std::memory_order_relaxed);
  }
  erika_image_rgba_free(&work->rgba);
  ReleaseHdrReservation(&work->hdr_reservation_held);
  napi_delete_async_work(env, work->async_work);
  const uint64_t runtime_generation = work->runtime_generation;
  delete work;
  FinishAsyncWork(runtime_generation);
  if (RuntimeIsActive(runtime_generation)) {
    QueueNextImageDecode();
  }
}

napi_value RejectedPromise(napi_env env, ErikaImageErrorKind kind,
                           const std::string &message) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  napi_create_promise(env, &deferred, &promise);
  napi_reject_deferred(env, deferred, ErrorValue(env, kind, message));
  return promise;
}

void RejectAndDeleteQueuedImageWork(ImageDecodeWork *work,
                                    ErikaImageErrorKind kind,
                                    const std::string &message) {
  napi_env env = work->env;
  ReleaseHdrReservation(&work->hdr_reservation_held);
  if (RuntimeIsActive(work->runtime_generation)) {
    napi_reject_deferred(env, work->deferred, ErrorValue(env, kind, message));
  }
  napi_delete_async_work(env, work->async_work);
  const uint64_t runtime_generation = work->runtime_generation;
  delete work;
  FinishAsyncWork(runtime_generation);
}

void QueueNextImageDecode() {
  while (true) {
    ImageDecodeWork *work = nullptr;
    {
      std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
      if (g_active_decode_work != nullptr) {
        return;
      }
      while (!g_decode_queue.empty()) {
        work = g_decode_queue.front();
        g_decode_queue.pop_front();
        if (work->cancelled.load(std::memory_order_acquire)) {
          g_image_jobs.erase(work->client_operation_id);
          break;
        }
        work->scheduled = true;
        g_active_decode_work = work;
        break;
      }
    }
    if (work == nullptr) {
      return;
    }
    if (work->cancelled.load(std::memory_order_acquire)) {
      g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);
      RejectAndDeleteQueuedImageWork(work, ErikaImageErrorKind_Cancelled,
                                     "Erika static image decode was cancelled");
      continue;
    }

    napi_status queue_status = napi_queue_async_work_with_qos(
        work->env, work->async_work, napi_qos_user_initiated);
    if (queue_status != napi_ok) {
      queue_status = napi_queue_async_work(work->env, work->async_work);
    }
    if (queue_status == napi_ok) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
      if (g_active_decode_work == work) {
        g_active_decode_work = nullptr;
      }
      g_image_jobs.erase(work->client_operation_id);
    }
    g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);
    RejectAndDeleteQueuedImageWork(work, ErikaImageErrorKind_Busy,
                                   "Unable to queue image decode work");
  }
}

napi_value NativeDecodeImage(napi_env env, napi_callback_info info, bool hdr) {
  size_t argc = 4;
  napi_value args[4] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "operationId and local path are required");
  }
  const uint64_t operation_id = GetUint64(env, args[0]);
  const std::string path = GetString(env, args[1]);
  const uint64_t runtime_generation =
      g_current_runtime_generation.load(std::memory_order_acquire);
  if (!RuntimeIsActive(runtime_generation)) {
    return RejectedPromise(env, ErikaImageErrorKind_Busy,
                           "Erika image environment is closing");
  }
  if (operation_id == 0 || path.empty()) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "operationId and local path are invalid");
  }
  if (hdr && !TryReserveHdrImage()) {
    return RejectedPromise(
        env, ErikaImageErrorKind_ResourceLimit,
        "Only one standalone HDR image session may be active");
  }

  auto *work = new (std::nothrow) ImageDecodeWork();
  if (work == nullptr) {
    bool reservation_held = hdr;
    ReleaseHdrReservation(&reservation_held);
    return RejectedPromise(env, ErikaImageErrorKind_ResourceLimit,
                           "Unable to allocate image decode work");
  }
  work->env = env;
  work->runtime_generation = runtime_generation;
  work->client_operation_id = operation_id;
  work->native_operation_id = NextNativeOperationId();
  work->path = path;
  work->hdr = hdr;
  work->hdr_reservation_held = hdr;
  work->max_width = argc > 2 ? GetUint32(env, args[2]) : 0;
  work->max_height = argc > 3 ? GetUint32(env, args[3]) : 0;

  napi_value promise = nullptr;
  if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
    ReleaseHdrReservation(&work->hdr_reservation_held);
    delete work;
    return Undefined(env);
  }
  napi_value resource_name = String(env, "ErikaStaticImageDecode");
  const napi_status create_status =
      napi_create_async_work(env, nullptr, resource_name, ExecuteImageDecode,
                             CompleteImageDecode, work, &work->async_work);
  if (create_status != napi_ok) {
    napi_reject_deferred(env, work->deferred,
                         ErrorValue(env, ErikaImageErrorKind_Internal,
                                    "Unable to create image async work"));
    ReleaseHdrReservation(&work->hdr_reservation_held);
    delete work;
    return promise;
  }

  {
    std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
    if (g_image_jobs.size() >= kMaxQueuedImageDecodes) {
      napi_delete_async_work(env, work->async_work);
      napi_reject_deferred(env, work->deferred,
                           ErrorValue(env, ErikaImageErrorKind_Busy,
                                      "Static image decode queue is full"));
      ReleaseHdrReservation(&work->hdr_reservation_held);
      delete work;
      return promise;
    }
    if (g_image_jobs.find(operation_id) != g_image_jobs.end()) {
      napi_delete_async_work(env, work->async_work);
      napi_reject_deferred(env, work->deferred,
                           ErrorValue(env, ErikaImageErrorKind_Busy,
                                      "operationId is already active"));
      ReleaseHdrReservation(&work->hdr_reservation_held);
      delete work;
      return promise;
    }
    g_image_jobs.emplace(operation_id, work);
    g_decode_queue.push_back(work);
  }
  AddAsyncWork(runtime_generation);
  g_queued_decodes.fetch_add(1, std::memory_order_relaxed);
  QueueNextImageDecode();
  return promise;
}

napi_value NativeDecodeSdrImage(napi_env env, napi_callback_info info) {
  return NativeDecodeImage(env, info, false);
}

napi_value NativeDecodeHdrImage(napi_env env, napi_callback_info info) {
  return NativeDecodeImage(env, info, true);
}

napi_value NativeCancelImageDecode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc == 0) {
    return Boolean(env, false);
  }
  const uint64_t operation_id = GetUint64(env, args[0]);
  ImageDecodeWork *cancelled_queued_work = nullptr;
  bool found_work = false;
  {
    std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
    const auto found = g_image_jobs.find(operation_id);
    if (found != g_image_jobs.end()) {
      ImageDecodeWork *work = found->second;
      found_work = true;
      work->cancelled.store(true, std::memory_order_release);
      {
        std::lock_guard<std::mutex> native_lock(work->native_state_mutex);
        if (work->native_decode_active) {
          erika_image_cancel_decode(work->native_operation_id);
        }
      }
      if (!work->scheduled) {
        const auto queued =
            std::find(g_decode_queue.begin(), g_decode_queue.end(), work);
        if (queued != g_decode_queue.end()) {
          g_decode_queue.erase(queued);
        }
        g_image_jobs.erase(found);
        cancelled_queued_work = work;
      } else if (work->stage.load(std::memory_order_acquire) ==
                     ImageWorkStage::kQueued &&
                 napi_cancel_async_work(work->env, work->async_work) ==
                     napi_ok) {
        g_cancelled_queued.fetch_add(1, std::memory_order_relaxed);
      }
    }
  }
  if (cancelled_queued_work != nullptr) {
    g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);
    g_cancelled_queued.fetch_add(1, std::memory_order_relaxed);
    RejectAndDeleteQueuedImageWork(cancelled_queued_work,
                                   ErikaImageErrorKind_Cancelled,
                                   "Erika static image decode was cancelled");
  }
  return Boolean(env, found_work);
}

napi_value NativeImageCapabilities(napi_env env, napi_callback_info) {
  napi_value value = nullptr;
  napi_create_object(env, &value);
  Set(env, value, "sdrDecodeSupported", Boolean(env, true));
  // This means the native XComponent surface path exists. Actual display HDR
  // is confirmed only by a rendered status with hdrOutputConfirmed=true.
  Set(env, value, "hdrSurfaceSupported", Boolean(env, true));
  Set(env, value, "networkSourceSupported", Boolean(env, false));
  Set(env, value, "activeBackend", String(env, "software"));
  Set(env, value, "maxEncodedBytes", Uint64Number(env, kMaxEncodedBytes));
  Set(env, value, "maxSourcePixels", Uint64Number(env, kMaxSourcePixels));
  Set(env, value, "maxSdrOutputPixels", Uint64Number(env, kMaxSdrOutputPixels));
  Set(env, value, "maxConcurrentDecodes", Uint32(env, 1));
  Set(env, value, "maxActiveHdrImages", Uint32(env, kMaxActiveHdrImages));
  return value;
}

napi_value NativeImageDiagnostics(napi_env env, napi_callback_info) {
  napi_value value = nullptr;
  napi_create_object(env, &value);
  Set(env, value, "queued", Uint64Number(env, g_queued_decodes.load()));
  Set(env, value, "inflight", Uint64Number(env, g_inflight_decodes.load()));
  Set(env, value, "decodeCount", Uint64Number(env, g_decode_count.load()));
  Set(env, value, "queuedCancelled",
      Uint64Number(env, g_cancelled_queued.load()));
  Set(env, value, "nativeHandleCount",
      Uint64Number(env, g_active_handles.load()));
  {
    std::lock_guard<std::mutex> lock(g_image_sessions_mutex);
    Set(env, value, "hdrHandleCount",
        Uint64Number(env, g_image_sessions.size()));
  }
  Set(env, value, "activeBackend", String(env, "software"));
  return value;
}

void SetSurfaceWorkError(ImageSurfaceWork *work, ErikaStatus status,
                         ErikaImageErrorKind error_kind, std::string error) {
  work->status = status;
  work->error_kind = error_kind;
  work->error = std::move(error);
}

void CaptureSurfaceWorkError(ImageSurfaceWork *work, ErikaStatus status) {
  const ErikaImageErrorKind error_kind = erika_image_last_error_kind();
  const std::string error = LastErrorMessage();
  SetSurfaceWorkError(work, status, error_kind, error);
}

bool SurfaceOwnerMatches(const ImageSurfaceWork &work) {
  return work.image->window != nullptr &&
         work.image->surface_generation == work.surface_generation;
}

void ExecuteImageSurfaceWork(napi_env, void *data) {
  auto *work = static_cast<ImageSurfaceWork *>(data);
  const bool explicit_destroy =
      work->operation == ImageSurfaceOperation::kDestroy;
  if (!explicit_destroy && !RuntimeIsActive(work->runtime_generation)) {
    SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                        ErikaImageErrorKind_Cancelled,
                        "Erika image environment is closing");
    return;
  }

  std::lock_guard<std::mutex> lock(work->image->mutex);
  OhosImageSession &image = *work->image;
  if (image.runtime_generation != work->runtime_generation) {
    SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                        ErikaImageErrorKind_Cancelled,
                        "Stale Erika image runtime generation");
    return;
  }

  if (explicit_destroy) {
    const ErikaImageHandle handle = image.handle;
    if (handle != 0) {
      const ErikaStatus status = erika_image_destroy(handle);
      if (status != ErikaStatus_Ok) {
        CaptureSurfaceWorkError(work, status);
      }
      image.handle = 0;
      g_active_handles.fetch_sub(1, std::memory_order_relaxed);
    }
    ReleaseHdrReservation(&image.hdr_reservation_held);
    // erika_image_destroy synchronously waits for active calls and drops the
    // renderer (and therefore its raw OHNativeWindow use) before this release.
    if (image.window != nullptr) {
      OH_NativeWindow_DestroyNativeWindow(image.window);
      image.window = nullptr;
    }
    image.surface_state = {};
    return;
  }

  if (image.closing.load(std::memory_order_acquire)) {
    SetSurfaceWorkError(work, ErikaStatus_PlayerError, ErikaImageErrorKind_Busy,
                        "HDR image is being disposed");
    return;
  }

  if (work->operation == ImageSurfaceOperation::kAttach) {
    if (work->surface_generation == 0) {
      SetSurfaceWorkError(work, ErikaStatus_NullPointer,
                          ErikaImageErrorKind_Source,
                          "surfaceGeneration must be non-zero");
      return;
    }
    if (work->surface_generation <= image.surface_generation) {
      SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                          ErikaImageErrorKind_Cancelled,
                          "Stale HDR XComponent surface generation");
      return;
    }
    if (image.window != nullptr) {
      const ErikaStatus detach_status =
          DetachWindowLocked(image, &work->error_kind, &work->error);
      if (detach_status != ErikaStatus_Ok) {
        work->status = detach_status;
        return;
      }
    }

    OHNativeWindow *window = nullptr;
    if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(work->surface_id,
                                                        &window) != 0 ||
        window == nullptr) {
      SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                          ErikaImageErrorKind_Renderer,
                          "Unable to acquire the XComponent native window");
      return;
    }
    const bool source_is_hdr = image.metadata.source_dynamic_range == 2 ||
                               image.metadata.source_dynamic_range == 3 ||
                               image.metadata.source_dynamic_range == 4;
    ErikaHarmonyNextConfigureSurface(window, source_is_hdr,
                                     &image.surface_state);
    ErikaSurfaceOutputCapabilities capabilities = {};
    capabilities.extended_linear = image.surface_state.hdr_surface_supported;
    capabilities.direct_composition = true;
    capabilities.desired_headroom =
        image.surface_state.hdr_surface_supported ? 4.0f : 1.0f;
    capabilities.fallback_reason = image.surface_state.fallback_reason;
    capabilities.native_data_space = image.surface_state.native_color_space;
    const ErikaStatus attach_status = erika_image_attach_wgpu_surface(
        image.handle, ErikaWgpuSurfaceKind_OhosNativeWindow,
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(window)), 0,
        work->width, work->height, work->scale, capabilities);
    if (attach_status != ErikaStatus_Ok) {
      CaptureSurfaceWorkError(work, attach_status);
      OH_NativeWindow_DestroyNativeWindow(window);
      return;
    }
    image.window = window;
    image.surface_generation = work->surface_generation;
  } else if (!SurfaceOwnerMatches(*work)) {
    if (work->operation == ImageSurfaceOperation::kDetach) {
      // A stale XComponent destruction is an idempotent no-op. It must never
      // detach the newer surface generation.
      return;
    }
    SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                        ErikaImageErrorKind_Cancelled,
                        "Stale or detached HDR XComponent surface generation");
    return;
  }

  if (work->operation == ImageSurfaceOperation::kDetach) {
    const ErikaStatus detach_status =
        DetachWindowLocked(image, &work->error_kind, &work->error);
    if (detach_status != ErikaStatus_Ok) {
      work->status = detach_status;
    }
    return;
  }

  if (work->operation == ImageSurfaceOperation::kResize) {
    const ErikaStatus resize_status = erika_image_resize_surface(
        image.handle, work->width, work->height, work->scale);
    if (resize_status != ErikaStatus_Ok) {
      CaptureSurfaceWorkError(work, resize_status);
      return;
    }
  }

  const ErikaStatus render_status = erika_image_render_surface(
      image.handle, &work->output, &work->dynamic_range);
  if (render_status != ErikaStatus_Ok) {
    CaptureSurfaceWorkError(work, render_status);
    if (work->operation == ImageSurfaceOperation::kAttach) {
      ErikaImageErrorKind cleanup_kind = ErikaImageErrorKind_None;
      std::string cleanup_error;
      DetachWindowLocked(image, &cleanup_kind, &cleanup_error);
    }
    return;
  }
  // This is the sole source of hdrOutputConfirmed. Surface configuration or
  // source metadata alone never promotes the status.
  work->has_output_status = true;
}

void QueueNextSurfaceWork();

void CompleteImageSurfaceWork(napi_env completion_env, napi_status async_status,
                              void *data) {
  auto *work = static_cast<ImageSurfaceWork *>(data);
  (void)completion_env;
  napi_env env = work->env;
  {
    std::lock_guard<std::mutex> lock(g_surface_jobs_mutex);
    if (g_active_surface_work == work) {
      g_active_surface_work = nullptr;
    }
  }
  if (async_status == napi_cancelled && work->status == ErikaStatus_Ok) {
    SetSurfaceWorkError(work, ErikaStatus_PlayerError,
                        ErikaImageErrorKind_Cancelled,
                        "Erika image surface operation was cancelled");
  }
  const uint64_t runtime_generation = work->runtime_generation;
  if (RuntimeIsActive(runtime_generation)) {
    napi_value value =
        work->has_output_status
            ? OutputStatusValue(env, work->output, work->dynamic_range)
            : nullptr;
    napi_resolve_deferred(
        env, work->deferred,
        Response(env, work->status, value, work->error_kind, work->error));
  }
  napi_delete_async_work(env, work->async_work);
  g_surface_work_count.fetch_sub(1, std::memory_order_relaxed);
  delete work;
  FinishAsyncWork(runtime_generation);
  if (RuntimeIsActive(runtime_generation)) {
    QueueNextSurfaceWork();
  }
}

void RejectAndDeleteSurfaceWork(ImageSurfaceWork *work,
                                ErikaImageErrorKind kind,
                                const std::string &message) {
  napi_env env = work->env;
  if (work->operation == ImageSurfaceOperation::kDestroy) {
    std::lock_guard<std::mutex> image_lock(work->image->mutex);
    work->image->closing.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> sessions_lock(g_image_sessions_mutex);
    g_image_sessions.emplace(work->image_id, work->image);
  }
  if (RuntimeIsActive(work->runtime_generation)) {
    napi_reject_deferred(env, work->deferred, ErrorValue(env, kind, message));
  }
  napi_delete_async_work(env, work->async_work);
  const uint64_t runtime_generation = work->runtime_generation;
  g_surface_work_count.fetch_sub(1, std::memory_order_relaxed);
  delete work;
  FinishAsyncWork(runtime_generation);
}

void QueueNextSurfaceWork() {
  while (true) {
    ImageSurfaceWork *work = nullptr;
    {
      std::lock_guard<std::mutex> lock(g_surface_jobs_mutex);
      if (g_active_surface_work != nullptr || g_surface_queue.empty()) {
        return;
      }
      work = g_surface_queue.front();
      g_surface_queue.pop_front();
      g_active_surface_work = work;
    }
    napi_status queue_status = napi_queue_async_work_with_qos(
        work->env, work->async_work, napi_qos_user_initiated);
    if (queue_status != napi_ok) {
      queue_status = napi_queue_async_work(work->env, work->async_work);
    }
    if (queue_status == napi_ok) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(g_surface_jobs_mutex);
      if (g_active_surface_work == work) {
        g_active_surface_work = nullptr;
      }
    }
    RejectAndDeleteSurfaceWork(work, ErikaImageErrorKind_Busy,
                               "Unable to queue image surface work");
  }
}

napi_value ScheduleSurfaceWork(napi_env env, ImageSurfaceWork *work) {
  if (work == nullptr) {
    return RejectedPromise(env, ErikaImageErrorKind_ResourceLimit,
                           "Unable to allocate image surface work");
  }
  if (!RuntimeIsActive(work->runtime_generation)) {
    delete work;
    return RejectedPromise(env, ErikaImageErrorKind_Busy,
                           "Erika image environment is closing");
  }
  // Bind every work item to the N-API environment that created its Promise.
  // Cleanup and cancellation can remove an item before it ever reaches the
  // N-API queue, so they must not infer the environment from an active job.
  work->env = env;
  napi_value promise = nullptr;
  if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
    delete work;
    return Undefined(env);
  }
  napi_value resource_name = String(env, "ErikaStaticImageSurface");
  if (napi_create_async_work(env, nullptr, resource_name,
                             ExecuteImageSurfaceWork, CompleteImageSurfaceWork,
                             work, &work->async_work) != napi_ok) {
    napi_reject_deferred(env, work->deferred,
                         ErrorValue(env, ErikaImageErrorKind_Internal,
                                    "Unable to create surface async work"));
    delete work;
    return promise;
  }
  if (g_surface_work_count.fetch_add(1, std::memory_order_relaxed) >=
      kMaxQueuedImageDecodes * 2) {
    g_surface_work_count.fetch_sub(1, std::memory_order_relaxed);
    napi_delete_async_work(env, work->async_work);
    napi_reject_deferred(env, work->deferred,
                         ErrorValue(env, ErikaImageErrorKind_Busy,
                                    "Image surface queue is full"));
    delete work;
    return promise;
  }
  if (work->operation == ImageSurfaceOperation::kDestroy) {
    work->image->closing.store(true, std::memory_order_release);
    std::lock_guard<std::mutex> sessions_lock(g_image_sessions_mutex);
    const auto found = g_image_sessions.find(work->image_id);
    if (found != g_image_sessions.end() && found->second == work->image) {
      g_image_sessions.erase(found);
    }
  }
  AddAsyncWork(work->runtime_generation);
  {
    std::lock_guard<std::mutex> lock(g_surface_jobs_mutex);
    g_surface_queue.push_back(work);
  }
  QueueNextSurfaceWork();
  return promise;
}

ImageSurfaceWork *NewSurfaceWork(uint64_t runtime_generation, uint64_t image_id,
                                 ImageSurfaceOperation operation) {
  const auto image = FindImage(image_id);
  if (image == nullptr || image->runtime_generation != runtime_generation) {
    return nullptr;
  }
  auto *work = new (std::nothrow) ImageSurfaceWork();
  if (work != nullptr) {
    work->runtime_generation = runtime_generation;
    work->image_id = image_id;
    work->operation = operation;
    work->image = image;
  }
  return work;
}

napi_value NativeAttachHdrImageSurface(napi_env env, napi_callback_info info) {
  size_t argc = 6;
  napi_value args[6] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 6) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "imageId, surfaceId, surfaceGeneration, width, "
                           "height, and scale are required");
  }
  const uint64_t runtime_generation = g_current_runtime_generation.load();
  auto *work = NewSurfaceWork(runtime_generation, GetUint64(env, args[0]),
                              ImageSurfaceOperation::kAttach);
  if (work == nullptr) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Unknown HDR image session");
  }
  work->surface_id = GetUint64(env, args[1]);
  work->surface_generation = GetUint64(env, args[2]);
  work->width = GetUint32(env, args[3]);
  work->height = GetUint32(env, args[4]);
  work->scale = GetDouble(env, args[5]);
  if (!RuntimeIsActive(runtime_generation) || work->surface_id == 0 ||
      work->surface_generation == 0 || work->width == 0 || work->height == 0 ||
      work->scale <= 0.0) {
    delete work;
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Invalid HDR surface arguments");
  }
  return ScheduleSurfaceWork(env, work);
}

napi_value NativeResizeHdrImageSurface(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 5) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Invalid HDR resize arguments");
  }
  const uint64_t runtime_generation = g_current_runtime_generation.load();
  auto *work = NewSurfaceWork(runtime_generation, GetUint64(env, args[0]),
                              ImageSurfaceOperation::kResize);
  if (work == nullptr) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Unknown HDR image session");
  }
  work->surface_generation = GetUint64(env, args[1]);
  work->width = GetUint32(env, args[2]);
  work->height = GetUint32(env, args[3]);
  work->scale = GetDouble(env, args[4]);
  if (work->surface_generation == 0 || work->width == 0 || work->height == 0 ||
      work->scale <= 0.0) {
    delete work;
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Invalid HDR resize arguments");
  }
  return ScheduleSurfaceWork(env, work);
}

napi_value NativeRenderHdrImageSurface(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Invalid HDR render arguments");
  }
  const uint64_t runtime_generation = g_current_runtime_generation.load();
  auto *work = NewSurfaceWork(runtime_generation, GetUint64(env, args[0]),
                              ImageSurfaceOperation::kRender);
  if (work == nullptr) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Unknown HDR image session");
  }
  work->surface_generation = GetUint64(env, args[1]);
  return ScheduleSurfaceWork(env, work);
}

napi_value NativeDetachHdrImageSurface(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Invalid HDR detach arguments");
  }
  const uint64_t runtime_generation = g_current_runtime_generation.load();
  auto *work = NewSurfaceWork(runtime_generation, GetUint64(env, args[0]),
                              ImageSurfaceOperation::kDetach);
  if (work == nullptr) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "Unknown HDR image session");
  }
  work->surface_generation = GetUint64(env, args[1]);
  return ScheduleSurfaceWork(env, work);
}

napi_value NativeDestroyHdrImage(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc == 0) {
    return RejectedPromise(env, ErikaImageErrorKind_Source,
                           "imageId is required");
  }
  const uint64_t runtime_generation = g_current_runtime_generation.load();
  const uint64_t image_id = GetUint64(env, args[0]);
  auto *work = NewSurfaceWork(runtime_generation, image_id,
                              ImageSurfaceOperation::kDestroy);
  if (work == nullptr) {
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    napi_resolve_deferred(env, deferred, Response(env, ErikaStatus_Ok));
    return promise;
  }
  return ScheduleSurfaceWork(env, work);
}

void DestroySessionAfterRuntimeClose(
    const std::shared_ptr<OhosImageSession> &image) {
  if (image == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(image->mutex);
  if (image->handle != 0) {
    // Destroying the core handle first synchronously detaches/drops WGPU and
    // waits for active calls. Only then may the host release OHNativeWindow.
    erika_image_destroy(image->handle);
    image->handle = 0;
    g_active_handles.fetch_sub(1, std::memory_order_relaxed);
  }
  ReleaseHdrReservation(&image->hdr_reservation_held);
  if (image->window != nullptr) {
    OH_NativeWindow_DestroyNativeWindow(image->window);
    image->window = nullptr;
  }
  image->surface_state = {};
}

void CleanupImageEnvironment(napi_async_cleanup_hook_handle cleanup_handle,
                             void *data) {
  auto *cleanup = static_cast<ImageEnvironmentCleanup *>(data);
  const uint64_t generation = cleanup->runtime_generation;
  g_closing_runtime_generation.store(generation, std::memory_order_release);

  std::vector<ImageDecodeWork *> abandoned_decodes;
  {
    std::lock_guard<std::mutex> lock(g_image_jobs_mutex);
    for (auto iterator = g_decode_queue.begin();
         iterator != g_decode_queue.end();) {
      ImageDecodeWork *work = *iterator;
      if (work->runtime_generation == generation) {
        work->cancelled.store(true, std::memory_order_release);
        g_image_jobs.erase(work->client_operation_id);
        abandoned_decodes.push_back(work);
        iterator = g_decode_queue.erase(iterator);
      } else {
        ++iterator;
      }
    }
    if (g_active_decode_work != nullptr &&
        g_active_decode_work->runtime_generation == generation) {
      ImageDecodeWork *work = g_active_decode_work;
      work->cancelled.store(true, std::memory_order_release);
      {
        std::lock_guard<std::mutex> native_lock(work->native_state_mutex);
        if (work->native_decode_active) {
          erika_image_cancel_decode(work->native_operation_id);
        }
      }
      if (work->stage.load(std::memory_order_acquire) ==
          ImageWorkStage::kQueued) {
        napi_cancel_async_work(work->env, work->async_work);
      }
    }
  }
  for (ImageDecodeWork *work : abandoned_decodes) {
    g_queued_decodes.fetch_sub(1, std::memory_order_relaxed);
    napi_delete_async_work(work->env, work->async_work);
    FinishAsyncWork(work->runtime_generation);
    ReleaseHdrReservation(&work->hdr_reservation_held);
    delete work;
  }

  std::vector<ImageSurfaceWork *> abandoned_surfaces;
  {
    std::lock_guard<std::mutex> lock(g_surface_jobs_mutex);
    for (auto iterator = g_surface_queue.begin();
         iterator != g_surface_queue.end();) {
      ImageSurfaceWork *work = *iterator;
      if (work->runtime_generation == generation) {
        if (work->operation == ImageSurfaceOperation::kDestroy) {
          cleanup->orphaned_sessions.push_back(work->image);
        }
        abandoned_surfaces.push_back(work);
        iterator = g_surface_queue.erase(iterator);
      } else {
        ++iterator;
      }
    }
  }
  for (ImageSurfaceWork *work : abandoned_surfaces) {
    napi_delete_async_work(work->env, work->async_work);
    g_surface_work_count.fetch_sub(1, std::memory_order_relaxed);
    FinishAsyncWork(work->runtime_generation);
    delete work;
  }

  {
    std::lock_guard<std::mutex> lock(g_image_sessions_mutex);
    for (const auto &entry : g_image_sessions) {
      if (entry.second->runtime_generation == generation) {
        entry.second->closing.store(true, std::memory_order_release);
      }
    }
  }

  std::thread([cleanup_handle, cleanup, generation] {
    {
      std::unique_lock<std::mutex> lock(g_async_counts_mutex);
      g_async_counts_changed.wait(lock, [generation] {
        return g_async_counts.find(generation) == g_async_counts.end();
      });
    }
    std::vector<std::shared_ptr<OhosImageSession>> sessions;
    {
      std::lock_guard<std::mutex> lock(g_image_sessions_mutex);
      for (auto iterator = g_image_sessions.begin();
           iterator != g_image_sessions.end();) {
        if (iterator->second->runtime_generation == generation) {
          sessions.push_back(iterator->second);
          iterator = g_image_sessions.erase(iterator);
        } else {
          ++iterator;
        }
      }
    }
    sessions.insert(sessions.end(), cleanup->orphaned_sessions.begin(),
                    cleanup->orphaned_sessions.end());
    std::unordered_map<uint64_t, std::shared_ptr<OhosImageSession>>
        unique_sessions;
    for (const auto &image : sessions) {
      if (image != nullptr) {
        unique_sessions.emplace(image->handle, image);
      }
    }
    for (const auto &entry : unique_sessions) {
      DestroySessionAfterRuntimeClose(entry.second);
    }
    napi_remove_async_cleanup_hook(cleanup_handle);
    {
      std::lock_guard<std::mutex> lock(g_runtime_owner_mutex);
      if (g_registered_runtime_generation == generation) {
        g_registered_runtime_generation = 0;
      }
    }
    delete cleanup;
  }).detach();
}

} // namespace

napi_status ErikaOhosDefineImageExports(napi_env env, napi_value exports) {
  auto *cleanup = new (std::nothrow) ImageEnvironmentCleanup();
  if (cleanup == nullptr) {
    return napi_generic_failure;
  }
  napi_async_cleanup_hook_handle cleanup_handle = nullptr;
  uint64_t generation = 0;
  {
    // Ownership is independent of whether this runtime happens to have queued
    // work. From hook registration until cleanup has fully drained, no second
    // napi_env may share these process-global queues or session registries.
    std::lock_guard<std::mutex> lock(g_runtime_owner_mutex);
    if (g_registered_runtime_generation != 0) {
      delete cleanup;
      return napi_generic_failure;
    }
    generation =
        g_current_runtime_generation.fetch_add(1, std::memory_order_acq_rel) +
        1;
    cleanup->runtime_generation = generation;
    if (napi_add_async_cleanup_hook(env, CleanupImageEnvironment, cleanup,
                                    &cleanup_handle) != napi_ok) {
      delete cleanup;
      return napi_generic_failure;
    }
    g_registered_runtime_generation = generation;
  }
  napi_property_descriptor descriptors[] = {
      {"nativeGetImageCapabilities", nullptr, NativeImageCapabilities, nullptr,
       nullptr, nullptr, napi_default, nullptr},
      {"nativeGetImageDiagnostics", nullptr, NativeImageDiagnostics, nullptr,
       nullptr, nullptr, napi_default, nullptr},
      {"nativeDecodeSdrImage", nullptr, NativeDecodeSdrImage, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"nativeDecodeHdrImage", nullptr, NativeDecodeHdrImage, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"nativeCancelImageDecode", nullptr, NativeCancelImageDecode, nullptr,
       nullptr, nullptr, napi_default, nullptr},
      {"nativeAttachHdrImageSurface", nullptr, NativeAttachHdrImageSurface,
       nullptr, nullptr, nullptr, napi_default, nullptr},
      {"nativeResizeHdrImageSurface", nullptr, NativeResizeHdrImageSurface,
       nullptr, nullptr, nullptr, napi_default, nullptr},
      {"nativeRenderHdrImageSurface", nullptr, NativeRenderHdrImageSurface,
       nullptr, nullptr, nullptr, napi_default, nullptr},
      {"nativeDetachHdrImageSurface", nullptr, NativeDetachHdrImageSurface,
       nullptr, nullptr, nullptr, napi_default, nullptr},
      {"nativeDestroyHdrImage", nullptr, NativeDestroyHdrImage, nullptr,
       nullptr, nullptr, napi_default, nullptr},
  };
  const napi_status define_status = napi_define_properties(
      env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  if (define_status != napi_ok) {
    napi_remove_async_cleanup_hook(cleanup_handle);
    {
      std::lock_guard<std::mutex> lock(g_runtime_owner_mutex);
      if (g_registered_runtime_generation == generation) {
        g_registered_runtime_generation = 0;
      }
    }
    g_closing_runtime_generation.store(generation, std::memory_order_release);
    delete cleanup;
  }
  return define_status;
}
