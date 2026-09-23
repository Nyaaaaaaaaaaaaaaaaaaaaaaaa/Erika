#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>

#include <native_window/external_window.h>

#include "erika.h"

std::mutex& ErikaOhosPresenterMutex();

// Configures the NativeWindow for SDR before wgpu creates its swapchain.
// Returns the reported native color space, or -1 when it cannot be read.
int32_t ErikaHarmonyNextConfigureSdrSurface(OHNativeWindow* window);

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
