#include "include/erika_flutter/erika_flutter_plugin.h"
#include "include/erika_flutter/erika_flutter_image.h"

#include <napi/native_api.h>
#include <native_window/external_window.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include "erika.h"
#include "erika_harmony_next_surface.h"

// All presenter access, including DisplaySoloist callbacks, uses this gate.
// ArkTS submits one job at a time to preserve command/surface lifetime order.
std::mutex& ErikaOhosPresenterMutex() {
  static std::mutex mutex;
  return mutex;
}

namespace {
struct OhosPlayer {
  ErikaPresenterHandle* presenter = nullptr;
  OHNativeWindow* window = nullptr;
  bool hdr_requested = false;
  ErikaHarmonyNextSurfaceState surface_state;
  std::unique_ptr<ErikaHarmonyNextFrameDriver> frame_driver;
};
std::unordered_map<int64_t, OhosPlayer> g_players;
int64_t g_next_player_id = 1;

enum class Operation {
  Create, Destroy, Invoke, Font, Attach, Resize, Detach, Render, Poll, Capabilities, Capture
};
struct Method {
  const char* name;
  Operation operation;
  // n = number, s = string, b = byte array; copied on the env thread.
  const char* signature;
};
const Method kMethods[] = {
    {"nativeCreate", Operation::Create, "nnn"},
    {"nativeDestroy", Operation::Destroy, "n"},
    {"nativeInvoke", Operation::Invoke, "nss"},
    {"nativeRegisterSubtitleMemoryFont", Operation::Font, "nb"},
    {"nativeAttachSurface", Operation::Attach, "nnnnn"},
    {"nativeResizeSurface", Operation::Resize, "nnnn"},
    {"nativeDetachSurface", Operation::Detach, "n"},
    {"nativeRenderTick", Operation::Render, "nn"},
    {"nativePollEvent", Operation::Poll, "n"},
    {"nativeGetHdrCapabilitiesJson", Operation::Capabilities, "n"},
    {"nativeCaptureFrame", Operation::Capture, "nnn"},
};
struct Request {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  const Method* method = nullptr;
  double numbers[5] = {};
  std::string strings[5];
  std::vector<uint8_t> input;
  enum class Kind { Null, Number, String, Bytes, Font } kind = Kind::Null;
  int64_t number = 0;
  std::string text;
  std::vector<uint8_t> bytes;
  std::string error;
};
napi_value String(napi_env env, const std::string& text) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, text.c_str(), text.size(), &result);
  return result;
}
std::string TakeString(char* text) {
  std::string result = text == nullptr ? "" : text;
  erika_string_free(text);
  return result;
}
void Fail(Request& request, const char* fallback) {
  // The error is thread-local. Copy it before cleanup or another C API call.
  request.error = TakeString(erika_last_error_message());
  if (request.error.empty()) request.error = fallback;
}
bool CheckStatus(Request& request, ErikaStatus status) {
  if (status != ErikaStatus_Ok) {
    Fail(request, "Erika native operation failed");
    return false;
  }
  request.kind = Request::Kind::Number;
  request.number = 0;
  return true;
}
void ReleaseWindow(OhosPlayer& player) {
  player.frame_driver->Stop();
  if (player.window != nullptr) {
    erika_presenter_detach_surface(player.presenter);
    OH_NativeWindow_DestroyNativeWindow(player.window);
    player.window = nullptr;
  }
}

// No napi_env/napi_value is accessed on this worker thread.
void Execute(napi_env, void* data) {
  auto& request = *static_cast<Request*>(data);
  std::lock_guard<std::mutex> lock(ErikaOhosPresenterMutex());
  const auto op = request.method->operation;
  const auto* n = request.numbers;
  if (op == Operation::Create) {
    ErikaPresenterConfig config = {};
    config.output_mode = n[0] == 0 ? 0 : 2;
    config.edr_headroom = static_cast<float>(n[1]);
    config.luma_upscaler = static_cast<int32_t>(n[2]);
    auto* presenter = erika_presenter_create_with_config(config);
    if (presenter == nullptr) { Fail(request, "Presenter creation failed"); return; }
    OhosPlayer player;
    player.presenter = presenter;
    player.hdr_requested = n[0] != 0;
    player.frame_driver.reset(new (std::nothrow) ErikaHarmonyNextFrameDriver());
    if (!player.frame_driver) {
      request.error = "Frame driver allocation failed";
      erika_presenter_destroy(presenter);
      return;
    }
    // Stale queued calls must not reach a newly allocated presenter.
    request.number = g_next_player_id++;
    request.kind = Request::Kind::Number;
    g_players.emplace(request.number, std::move(player));
    return;
  }
  const auto found = g_players.find(static_cast<int64_t>(n[0]));
  if (found == g_players.end()) {
    if (op != Operation::Destroy && op != Operation::Poll) request.error = "Unknown Erika player";
    return;
  }
  auto& player = found->second;
  switch (op) {
    case Operation::Create: break;
    case Operation::Destroy:
      ReleaseWindow(player);
      erika_presenter_destroy(player.presenter);
      g_players.erase(found);
      break;
    case Operation::Invoke:
      request.text = TakeString(erika_presenter_invoke_json(
          player.presenter, request.strings[1].c_str(), request.strings[2].c_str()));
      request.kind = Request::Kind::String;
      break;
    case Operation::Font: {
      uint64_t font_id = 0;
      if (CheckStatus(request, erika_presenter_register_subtitle_memory_font(
          player.presenter, request.input.data(), request.input.size(), &font_id))) {
        request.kind = Request::Kind::Font;
        request.number = static_cast<int64_t>(font_id);
      }
      break;
    }
    case Operation::Attach: {
      ReleaseWindow(player);
      OHNativeWindow* window = nullptr;
      if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(
              static_cast<uint64_t>(n[1]), &window) != 0 || window == nullptr) {
        request.error = "Native window creation failed";
        break;
      }
      ErikaHarmonyNextConfigureSurface(window, player.hdr_requested, &player.surface_state);
      ErikaSurfaceOutputCapabilities capabilities = {};
      capabilities.extended_linear = player.surface_state.hdr_surface_supported;
      capabilities.direct_composition = true;
      capabilities.desired_headroom = player.surface_state.hdr_surface_supported ? 4.0f : 1.0f;
      capabilities.fallback_reason = player.surface_state.fallback_reason;
      capabilities.native_data_space = player.surface_state.native_color_space;
      if (!CheckStatus(request, erika_presenter_attach_wgpu_surface_with_output_capabilities(
          player.presenter, ErikaWgpuSurfaceKind_OhosNativeWindow,
          static_cast<uint64_t>(reinterpret_cast<uintptr_t>(window)), 0,
          static_cast<uint32_t>(n[2]), static_cast<uint32_t>(n[3]), n[4], capabilities))) {
        OH_NativeWindow_DestroyNativeWindow(window);
        break;
      }
      player.window = window;
      if (!player.frame_driver->Start(player.presenter)) {
        player.surface_state.native_vsync_supported = false;
        player.surface_state.fallback_reason = ErikaOutputFallbackReason_NativeVsyncUnavailable;
        request.error = "Native vsync unavailable";
        ReleaseWindow(player);
        break;
      }
      player.surface_state.native_vsync_supported = true;
      break;
    }
    case Operation::Resize:
      CheckStatus(request, erika_presenter_resize_surface(player.presenter,
          static_cast<uint32_t>(n[1]), static_cast<uint32_t>(n[2]), n[3]));
      break;
    case Operation::Detach:
      player.frame_driver->Stop();
      CheckStatus(request, erika_presenter_detach_surface(player.presenter));
      if (player.window != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(player.window);
        player.window = nullptr;
      }
      player.surface_state = {};
      break;
    case Operation::Render:
      request.text = TakeString(erika_presenter_render_tick_json(player.presenter, n[1]));
      request.kind = Request::Kind::String;
      break;
    case Operation::Poll: {
      char* response = erika_presenter_poll_event_json(player.presenter);
      if (response != nullptr) {
        request.text = TakeString(response);
        request.kind = Request::Kind::String;
      }
      break;
    }
    case Operation::Capabilities:
      request.text = ErikaHarmonyNextCapabilitiesJson(player.surface_state);
      request.kind = Request::Kind::String;
      break;
    case Operation::Capture: {
      if (n[1] <= 0 || n[2] <= 0 || n[1] > INT32_MAX || n[2] > INT32_MAX) break;
      const auto width = static_cast<uint32_t>(n[1]);
      const auto height = static_cast<uint32_t>(n[2]);
      if (height > std::numeric_limits<size_t>::max() / width / 4) break;
      request.bytes.resize(static_cast<size_t>(width) * height * 4);
      if (CheckStatus(request, erika_presenter_capture_frame_rgba(player.presenter,
          width, height, request.bytes.data(), request.bytes.size()))) request.kind = Request::Kind::Bytes;
      break;
    }
  }
}

void Reject(napi_env env, Request& request) {
  napi_value error = nullptr;
  napi_create_error(env, nullptr, String(env, request.error), &error);
  napi_reject_deferred(env, request.deferred, error);
}
void Complete(napi_env env, napi_status status, void* data) {
  std::unique_ptr<Request> request(static_cast<Request*>(data));
  if (status != napi_ok && request->error.empty()) request->error = "Native work interrupted";
  napi_value value = nullptr;
  napi_get_null(env, &value);
  if (request->error.empty()) {
    switch (request->kind) {
      case Request::Kind::Null: break;
      case Request::Kind::Number:
        napi_create_int64(env, request->number, &value);
        break;
      case Request::Kind::String:
        value = String(env, request->text);
        break;
      case Request::Kind::Font: {
        napi_create_array_with_length(env, 2, &value);
        napi_value number = nullptr;
        napi_create_int32(env, 0, &number);
        napi_set_element(env, value, 0, number);
        napi_create_int64(env, request->number, &number);
        napi_set_element(env, value, 1, number);
        break;
      }
      case Request::Kind::Bytes: {
        void* bytes = nullptr;
        napi_value buffer = nullptr;
        if (napi_create_arraybuffer(env, request->bytes.size(), &bytes, &buffer) != napi_ok) {
          request->error = "Screenshot allocation failed";
          break;
        }
        memcpy(bytes, request->bytes.data(), request->bytes.size());
        if (napi_create_typedarray(env, napi_uint8_array, request->bytes.size(),
            buffer, 0, &value) != napi_ok) request->error = "Screenshot allocation failed";
        break;
      }
    }
  }
  if (request->error.empty()) napi_resolve_deferred(env, request->deferred, value);
  else Reject(env, *request);
  napi_delete_async_work(env, request->work);
}

napi_value Dispatch(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5] = {};
  void* method = nullptr;
  napi_get_cb_info(env, info, &argc, args, nullptr, &method);
  auto request = std::make_unique<Request>();
  request->method = static_cast<const Method*>(method);
  napi_value promise = nullptr;
  napi_create_promise(env, &request->deferred, &promise);
  const size_t expected = strlen(request->method->signature);
  if (argc != expected) request->error = "Invalid native argument count";
  for (size_t i = 0; i < expected && request->error.empty(); ++i) {
    const char type = request->method->signature[i];
    if (type == 'n') {
      if (napi_get_value_double(env, args[i], &request->numbers[i]) != napi_ok ||
          !std::isfinite(request->numbers[i]) || std::abs(request->numbers[i]) > 9007199254740991.0) {
        request->error = "Invalid native number";
      }
    } else if (type == 's') {
      size_t size = 0;
      if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &size) != napi_ok) {
        request->error = "Invalid native string";
        break;
      }
      request->strings[i].resize(size + 1);
      napi_get_value_string_utf8(env, args[i], request->strings[i].data(), size + 1, &size);
      request->strings[i].resize(size);
    } else {
      napi_typedarray_type array_type;
      size_t length = 0, offset = 0;
      void* bytes = nullptr;
      napi_value buffer = nullptr;
      if (napi_get_typedarray_info(env, args[i], &array_type, &length, &bytes, &buffer, &offset) != napi_ok ||
          (array_type != napi_uint8_array && array_type != napi_uint8_clamped_array)) {
        request->error = "Invalid native byte array";
        break;
      }
      if (length > 0) request->input.assign(static_cast<uint8_t*>(bytes), static_cast<uint8_t*>(bytes) + length);
    }
  }
  if (request->error.empty() && napi_create_async_work(env, nullptr,
      String(env, request->method->name), Execute, Complete, request.get(), &request->work) != napi_ok) {
    request->error = "Cannot create native work";
  }
  if (request->error.empty() && napi_queue_async_work(env, request->work) != napi_ok) {
    request->error = "Cannot queue native work";
  }
  if (!request->error.empty()) {
    Reject(env, *request);
    if (request->work != nullptr) napi_delete_async_work(env, request->work);
  } else {
    request.release(); // Complete owns this context, including copied input.
  }
  return promise;
}
napi_value Init(napi_env env, napi_value exports) {
  for (const auto& method : kMethods) {
    napi_property_descriptor descriptor = {method.name, nullptr, Dispatch, nullptr,
        nullptr, nullptr, napi_default, const_cast<Method*>(&method)};
    if (napi_define_properties(env, exports, 1, &descriptor) != napi_ok) {
      return nullptr;
    }
  }
  if (ErikaFlutterDefineImageExports(env, exports) != napi_ok) {
    return nullptr;
  }
  return exports;
}
}  // namespace

NAPI_MODULE(erika_flutter, Init)
