#include "erika_harmony_next_surface.h"

#include <native_buffer/buffer_common.h>
#include <native_buffer/native_buffer.h>
#include <native_display_soloist/native_display_soloist.h>

namespace {

constexpr int32_t kOk = 0;

}  // namespace

int32_t ErikaHarmonyNextConfigureSdrSurface(OHNativeWindow* window) {
  if (window == nullptr) {
    return -1;
  }
  OH_NativeWindow_NativeWindowHandleOpt(
      window, SET_FORMAT, static_cast<int32_t>(NATIVEBUFFER_PIXEL_FMT_RGBA_8888));
  OH_NativeWindow_SetColorSpace(window, OH_COLORSPACE_SRGB_FULL);
  OH_NativeWindow_NativeWindowHandleOpt(
      window, SET_COLOR_GAMUT, static_cast<int32_t>(NATIVEBUFFER_COLOR_GAMUT_SRGB));
  const float hdr_white_point = 0.0f;
  const float sdr_white_point = 1.0f;
  OH_NativeWindow_NativeWindowHandleOpt(
      window, SET_HDR_WHITE_POINT_BRIGHTNESS, hdr_white_point);
  OH_NativeWindow_NativeWindowHandleOpt(
      window, SET_SDR_WHITE_POINT_BRIGHTNESS, sdr_white_point);
  OH_NativeBuffer_ColorSpace color_space = OH_COLORSPACE_NONE;
  if (OH_NativeWindow_GetColorSpace(window, &color_space) == kOk) {
    return static_cast<int32_t>(color_space);
  }
  return -1;
}

ErikaHarmonyNextFrameDriver::ErikaHarmonyNextFrameDriver() = default;

ErikaHarmonyNextFrameDriver::~ErikaHarmonyNextFrameDriver() {
  Stop();
}

bool ErikaHarmonyNextFrameDriver::Start(ErikaPresenterHandle* presenter) {
  Stop();
  if (presenter == nullptr) {
    return false;
  }
  soloist_ = OH_DisplaySoloist_Create(false);
  supported_.store(soloist_ != nullptr, std::memory_order_release);
  if (soloist_ == nullptr) {
    return false;
  }
  DisplaySoloist_ExpectedRateRange range = {30, 120, 60};
  OH_DisplaySoloist_SetExpectedFrameRateRange(soloist_, &range);
  presenter_.store(presenter, std::memory_order_release);
  running_.store(
      OH_DisplaySoloist_Start(soloist_, OnFrame, this) == kOk,
      std::memory_order_release);
  if (!running_.load(std::memory_order_acquire)) {
    presenter_.store(nullptr, std::memory_order_release);
    OH_DisplaySoloist_Destroy(soloist_);
    soloist_ = nullptr;
  }
  return running_;
}

void ErikaHarmonyNextFrameDriver::Stop() {
  if (soloist_ == nullptr) {
    running_.store(false, std::memory_order_release);
    presenter_.store(nullptr, std::memory_order_release);
    return;
  }
  running_.store(false, std::memory_order_release);
  OH_DisplaySoloist_Stop(soloist_);
  presenter_.store(nullptr, std::memory_order_release);
  OH_DisplaySoloist_Destroy(soloist_);
  soloist_ = nullptr;
}

void ErikaHarmonyNextFrameDriver::OnFrame(
    long long timestamp,
    long long target_timestamp,
    void* data) {
  // Never wait for a worker that may be stopping this DisplaySoloist. Acquire
  // before dereferencing callback-owned data, and skip frames during commands.
  std::unique_lock<std::mutex> lock(ErikaOhosPresenterMutex(), std::try_to_lock);
  if (!lock.owns_lock()) return;
  auto* driver = static_cast<ErikaHarmonyNextFrameDriver*>(data);
  if (driver == nullptr ||
      !driver->running_.load(std::memory_order_acquire)) {
    return;
  }
  ErikaPresenterHandle* presenter =
      driver->presenter_.load(std::memory_order_acquire);
  if (presenter == nullptr) {
    return;
  }
  const long long render_timestamp = target_timestamp > 0 ? target_timestamp : timestamp;
  char* response = erika_presenter_render_tick_json(
      presenter, static_cast<double>(render_timestamp) / 1'000'000'000.0);
  erika_string_free(response);
}
