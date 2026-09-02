#include "erika_harmony_next_surface.h"

#include <native_buffer/buffer_common.h>
#include <native_buffer/native_buffer.h>
#include <native_display_soloist/native_display_soloist.h>
#include <multimedia/player_framework/native_avcapability.h>

#include <cstring>
#include <sstream>

namespace {

constexpr int32_t kOk = 0;

void ConfigureSdrFallback(OHNativeWindow* window) {
  if (window == nullptr) {
    return;
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
}

bool ReadBackMetadata(
    OHNativeWindow* window,
    OH_NativeBuffer_MetadataKey key,
    const void* expected,
    int32_t expected_size) {
  int32_t size = 0;
  uint8_t* value = nullptr;
  return OH_NativeWindow_GetMetadataValue(window, key, &size, &value) == kOk &&
      value != nullptr && size == expected_size &&
      std::memcmp(value, expected, static_cast<size_t>(expected_size)) == 0;
}

bool ConfigureAndVerifyHdrMetadata(OHNativeWindow* window) {
  OH_NativeBuffer_MetadataType metadata_type = OH_VIDEO_HDR_HDR10;
  if (OH_NativeWindow_SetMetadataValue(
          window,
          OH_HDR_METADATA_TYPE,
          static_cast<int32_t>(sizeof(metadata_type)),
          reinterpret_cast<uint8_t*>(&metadata_type)) != kOk) {
    return false;
  }
  if (!ReadBackMetadata(
          window, OH_HDR_METADATA_TYPE, &metadata_type, sizeof(metadata_type))) {
    return false;
  }

  OH_NativeBuffer_StaticMetadata metadata = {};
  metadata.smpte2086.displayPrimaryRed = {0.708f, 0.292f};
  metadata.smpte2086.displayPrimaryGreen = {0.170f, 0.797f};
  metadata.smpte2086.displayPrimaryBlue = {0.131f, 0.046f};
  metadata.smpte2086.whitePoint = {0.3127f, 0.3290f};
  metadata.smpte2086.maxLuminance = 1000.0f;
  metadata.smpte2086.minLuminance = 0.005f;
  metadata.cta861.maxContentLightLevel = 1000.0f;
  metadata.cta861.maxFrameAverageLightLevel = 400.0f;
  if (OH_NativeWindow_SetMetadataValue(
          window,
          OH_HDR_STATIC_METADATA,
          static_cast<int32_t>(sizeof(metadata)),
          reinterpret_cast<uint8_t*>(&metadata)) != kOk) {
    return false;
  }
  return ReadBackMetadata(
      window, OH_HDR_STATIC_METADATA, &metadata, sizeof(metadata));
}

bool HasHardwareAv1Decoder() {
  OH_AVCapability* capability =
      OH_AVCodec_GetCapabilityByCategory("video/av1", false, HARDWARE);
  return capability != nullptr && OH_AVCapability_IsHardware(capability);
}

void ReadBackColorSpace(
    OHNativeWindow* window,
    ErikaHarmonyNextSurfaceState* state) {
  OH_NativeBuffer_ColorSpace value = OH_COLORSPACE_NONE;
  if (window != nullptr && state != nullptr &&
      OH_NativeWindow_GetColorSpace(window, &value) == kOk) {
    state->native_color_space = static_cast<int32_t>(value);
  }
}

}  // namespace

bool ErikaHarmonyNextConfigureSurface(
    OHNativeWindow* window,
    bool request_hdr,
    ErikaHarmonyNextSurfaceState* state) {
  if (state == nullptr) {
    return false;
  }
  *state = {};
  state->known = window != nullptr;
  state->hdr_requested = request_hdr;
  if (window == nullptr) {
    state->fallback_reason = ErikaOutputFallbackReason_HdrWindowConfigurationFailed;
    return false;
  }
  if (!request_hdr) {
    ConfigureSdrFallback(window);
    ReadBackColorSpace(window, state);
    return true;
  }

  const bool format_set = OH_NativeWindow_NativeWindowHandleOpt(
                              window,
                              SET_FORMAT,
                              static_cast<int32_t>(NATIVEBUFFER_PIXEL_FMT_RGBA_1010102)) == kOk;
  int32_t format_after = 0;
  const bool format_verified = format_set &&
      OH_NativeWindow_NativeWindowHandleOpt(window, GET_FORMAT, &format_after) == kOk &&
      format_after == static_cast<int32_t>(NATIVEBUFFER_PIXEL_FMT_RGBA_1010102);
  const bool gamut_set = OH_NativeWindow_NativeWindowHandleOpt(
                             window,
                             SET_COLOR_GAMUT,
                             static_cast<int32_t>(NATIVEBUFFER_COLOR_GAMUT_BT2020)) == kOk;
  int32_t gamut_after = 0;
  const bool gamut_verified = gamut_set &&
      OH_NativeWindow_NativeWindowHandleOpt(window, GET_COLOR_GAMUT, &gamut_after) == kOk &&
      gamut_after == static_cast<int32_t>(NATIVEBUFFER_COLOR_GAMUT_BT2020);
  const bool color_set =
      OH_NativeWindow_SetColorSpace(window, OH_COLORSPACE_BT2020_PQ_LIMIT) == kOk;
  OH_NativeBuffer_ColorSpace color_after = OH_COLORSPACE_NONE;
  const bool color_verified = color_set &&
      OH_NativeWindow_GetColorSpace(window, &color_after) == kOk &&
      color_after == OH_COLORSPACE_BT2020_PQ_LIMIT;
  if (color_verified) {
    state->native_color_space = static_cast<int32_t>(color_after);
  }
  const float hdr_white_point = 1.0f;
  const float sdr_white_point = 0.203f;
  const bool white_points_set =
      OH_NativeWindow_NativeWindowHandleOpt(
          window, SET_HDR_WHITE_POINT_BRIGHTNESS, hdr_white_point) == kOk &&
      OH_NativeWindow_NativeWindowHandleOpt(
          window, SET_SDR_WHITE_POINT_BRIGHTNESS, sdr_white_point) == kOk;

  state->ten_bit_surface_supported = format_verified;
  state->hdr_metadata_configured = ConfigureAndVerifyHdrMetadata(window);
  state->hdr_surface_supported = format_verified && gamut_verified && color_verified &&
      white_points_set && state->hdr_metadata_configured;
  if (!state->hdr_surface_supported) {
    state->fallback_reason = !format_verified
        ? ErikaOutputFallbackReason_TenBitSurfaceFormatUnavailable
        : !state->hdr_metadata_configured
          ? ErikaOutputFallbackReason_HdrMetadataVerificationFailed
          : ErikaOutputFallbackReason_HdrWindowConfigurationFailed;
    ConfigureSdrFallback(window);
    ReadBackColorSpace(window, state);
    state->ten_bit_surface_supported = false;
    return false;
  }
  return true;
}

std::string ErikaHarmonyNextCapabilitiesJson(
    const ErikaHarmonyNextSurfaceState& state) {
  const bool hardware_av1_supported = HasHardwareAv1Decoder();
  std::ostringstream json;
  json << "{\"known\":" << (state.known ? "true" : "false")
       << ",\"supportedDynamicRanges\":[1";
  if (state.hdr_surface_supported) {
    // HLG sources are converted to the verified PQ output contract.
    json << ",2,3";
  }
  json << "]"
       << ",\"hdrSurfaceSupported\":"
       << (state.hdr_surface_supported ? "true" : "false")
       << ",\"tenBitSurfaceSupported\":"
       << (state.ten_bit_surface_supported ? "true" : "false")
       << ",\"hardwareAv1DecodeSupported\":"
       << (hardware_av1_supported ? "true" : "false")
       << ",\"hardwareAv1DecodeKnown\":true"
       << ",\"nativeVsyncSupported\":"
       << (state.native_vsync_supported ? "true" : "false")
       << ",\"fallbackReason\":" << state.fallback_reason << "}";
  return json.str();
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
