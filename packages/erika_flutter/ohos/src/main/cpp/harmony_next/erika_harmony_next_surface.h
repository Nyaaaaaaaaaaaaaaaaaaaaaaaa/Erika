#pragma once

#include <atomic>
#include <cstdint>
#include <string>

#include <native_window/external_window.h>

#include "erika.h"

struct ErikaHarmonyNextSurfaceState {
  bool known = false;
  bool hdr_requested = false;
  bool hdr_surface_supported = false;
  bool ten_bit_surface_supported = false;
  bool hdr_metadata_configured = false;
  bool native_vsync_supported = false;
  int32_t native_color_space = -1;
  int32_t fallback_reason = ErikaOutputFallbackReason_None;
};

// Configures and verifies the NativeWindow contract before wgpu creates its
// swapchain. On failure the function restores an explicit RGBA8888/sRGB
// contract and leaves an inspectable fallback reason in `state`.
bool ErikaHarmonyNextConfigureSurface(
    OHNativeWindow* window,
    bool request_hdr,
    ErikaHarmonyNextSurfaceState* state);

std::string ErikaHarmonyNextCapabilitiesJson(
    const ErikaHarmonyNextSurfaceState& state);

class ErikaHarmonyNextFrameDriver {
 public:
  ErikaHarmonyNextFrameDriver();
  ~ErikaHarmonyNextFrameDriver();

  ErikaHarmonyNextFrameDriver(const ErikaHarmonyNextFrameDriver&) = delete;
  ErikaHarmonyNextFrameDriver& operator=(const ErikaHarmonyNextFrameDriver&) = delete;

  bool Start(ErikaPresenterHandle* presenter);
  void Stop();
  bool supported() const { return supported_.load(std::memory_order_acquire); }
  bool running() const { return running_.load(std::memory_order_acquire); }

 private:
  static void OnFrame(long long timestamp, long long target_timestamp, void* data);

  struct OH_DisplaySoloist* soloist_ = nullptr;
  std::atomic<ErikaPresenterHandle*> presenter_{nullptr};
  std::atomic<bool> supported_{false};
  std::atomic<bool> running_{false};
};
