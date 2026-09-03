#import "ErikaImageNativeBridge.h"

#include "../../native/include/erika.h"

static NSString *ErikaImageLastError(void) {
  char *message = erika_last_error_message();
  if (message == NULL) {
    return @"Erika image operation failed";
  }
  NSString *value = [NSString stringWithUTF8String:message]
                        ?: @"Erika image operation failed";
  erika_string_free(message);
  return value;
}

static NSDictionary<NSString *, id> *ErikaImageFailure(int32_t status) {
  return @{
    @"ok" : @NO,
    @"status" : @(status),
    @"kind" : @(erika_image_last_error_kind()),
    @"error" : ErikaImageLastError(),
  };
}

static NSDictionary<NSString *, id> *ErikaImageSuccess(
    NSDictionary<NSString *, id> *value) {
  return @{
    @"ok" : @YES,
    @"status" : @0,
    @"value" : value,
  };
}

static NSDictionary<NSString *, id> *ErikaImageMetadataValue(
    ErikaImageMetadata metadata) {
  return @{
    @"width" : @(metadata.width),
    @"height" : @(metadata.height),
    @"bitDepth" : @(metadata.bit_depth),
    @"primaries" : @(metadata.primaries),
    @"transfer" : @(metadata.transfer),
    @"matrix" : @(metadata.matrix),
    @"colorRange" : @(metadata.color_range),
    @"sourceDynamicRange" : @(metadata.source_dynamic_range),
    @"decodeBackend" : @(metadata.decode_backend),
  };
}

@implementation ErikaImageNativeBridge

+ (NSDictionary<NSString *, id> *)decodeWithOperationId:(uint64_t)operationId
                                                    path:(NSString *)path
                                                maxWidth:(uint32_t)maxWidth
                                               maxHeight:(uint32_t)maxHeight
                                         maxEncodedBytes:(uint64_t)maxEncodedBytes
                                         maxSourcePixels:(uint64_t)maxSourcePixels
                                         maxOutputPixels:(uint64_t)maxOutputPixels
                               maxPacketsBeforeFrame:(uint32_t)maxPacketsBeforeFrame
                                decodeTimeoutMillis:(uint64_t)decodeTimeoutMillis {
  ErikaImageHandle handle = 0;
  ErikaImageDecodePolicy policy = {
      .max_input_bytes = maxEncodedBytes,
      .max_source_pixels = maxSourcePixels,
      .max_output_pixels = maxOutputPixels,
      .max_packets_before_frame = maxPacketsBeforeFrame,
      .decode_timeout_millis = decodeTimeoutMillis,
  };
  int32_t status = erika_image_decode_uri_sized_with_policy(
      operationId, path.fileSystemRepresentation, NULL, maxWidth, maxHeight,
      &policy, &handle);
  if (status != 0 || handle == 0) {
    return ErikaImageFailure(status);
  }

  ErikaImageMetadata metadata = {0};
  status = erika_image_get_metadata(handle, &metadata);
  if (status != 0) {
    NSDictionary<NSString *, id> *failure = ErikaImageFailure(status);
    erika_image_destroy(handle);
    return failure;
  }

  NSMutableDictionary<NSString *, id> *value =
      [ErikaImageMetadataValue(metadata) mutableCopy];
  value[@"imageId"] = @(handle);
  return ErikaImageSuccess(value);
}

+ (NSDictionary<NSString *, id> *)renderSdrWithHandle:(uint64_t)handle
                                              maxWidth:(uint32_t)maxWidth
                                             maxHeight:(uint32_t)maxHeight {
  ErikaImageRgba image = {0};
  int32_t status =
      erika_image_render_sdr_rgba(handle, maxWidth, maxHeight, &image);
  if (status != 0) {
    return ErikaImageFailure(status);
  }
  NSData *rgba = nil;
  if (image.data == NULL || image.layout.byte_len == 0) {
    rgba = [NSData data];
    erika_image_rgba_free(&image);
  } else {
    rgba = [[NSData alloc]
        initWithBytesNoCopy:image.data
                     length:image.layout.byte_len
                deallocator:^(void *bytes, NSUInteger length) {
                  ErikaImageRgba owned = {0};
                  owned.data = bytes;
                  owned.layout.byte_len = length;
                  erika_image_rgba_free(&owned);
                }];
    if (rgba == nil) {
      erika_image_rgba_free(&image);
      return ErikaImageFailure(ErikaStatus_PlayerError);
    }
    image.data = NULL;
    image.layout.byte_len = 0;
  }
  NSDictionary<NSString *, id> *value = @{
    @"width" : @(image.layout.width),
    @"height" : @(image.layout.height),
    @"rowBytes" : @(image.layout.row_bytes),
    @"rgba" : rgba,
  };
  return ErikaImageSuccess(value);
}

+ (NSDictionary<NSString *, id> *)attachSurfaceWithHandle:(uint64_t)handle
                                               metalLayer:(void *)metalLayer
                                                    width:(uint32_t)width
                                                   height:(uint32_t)height
                                                    scale:(double)scale
                                           extendedLinear:(BOOL)extendedLinear
                                        directComposition:(BOOL)directComposition
                                          desiredHeadroom:(float)desiredHeadroom
                                           fallbackReason:(int32_t)fallbackReason {
  ErikaSurfaceOutputCapabilities capabilities = {
      .extended_linear = extendedLinear,
      .direct_composition = directComposition,
      .desired_headroom = desiredHeadroom,
      .fallback_reason = fallbackReason,
      .native_data_space = 0,
  };
  // Erika's Apple wgpu path accepts a CAMetalLayer pointer through the
  // historical MacOsCaMetalLayer surface kind. IosUiView is intentionally not
  // used because it is not a wired raw-window target.
  int32_t status = erika_image_attach_wgpu_surface(
      handle, ErikaWgpuSurfaceKind_MacOsCaMetalLayer,
      (uint64_t)(uintptr_t)metalLayer, 0, width, height, scale,
      capabilities);
  return status == 0 ? ErikaImageSuccess(@{}) : ErikaImageFailure(status);
}

+ (NSDictionary<NSString *, id> *)resizeSurfaceWithHandle:(uint64_t)handle
                                                    width:(uint32_t)width
                                                   height:(uint32_t)height
                                                    scale:(double)scale {
  int32_t status = erika_image_resize_surface(handle, width, height, scale);
  return status == 0 ? ErikaImageSuccess(@{}) : ErikaImageFailure(status);
}

+ (NSDictionary<NSString *, id> *)renderSurfaceWithHandle:(uint64_t)handle {
  ErikaOutputStatus output = {0};
  ErikaDynamicRangeStatus dynamicRange = {0};
  int32_t status =
      erika_image_render_surface(handle, &output, &dynamicRange);
  if (status != 0) {
    return ErikaImageFailure(status);
  }
  return ErikaImageSuccess(@{
    @"hdrOutputConfirmed" : @(dynamicRange.hdr_output_confirmed),
    @"sourceDynamicRange" : @(dynamicRange.source_dynamic_range),
    @"activeDynamicRange" : @(dynamicRange.active_dynamic_range),
    @"activeEncoding" : @(output.active_encoding),
    @"fallbackReason" : @(output.fallback_reason),
    @"activeHeadroom" : @(output.active_headroom),
    @"activeHeadroomKnown" : @(output.active_headroom_known),
  });
}

+ (NSDictionary<NSString *, id> *)detachSurfaceWithHandle:(uint64_t)handle {
  int32_t status = erika_image_detach_surface(handle);
  return status == 0 ? ErikaImageSuccess(@{}) : ErikaImageFailure(status);
}

+ (NSDictionary<NSString *, id> *)destroyWithHandle:(uint64_t)handle {
  int32_t status = erika_image_destroy(handle);
  return status == 0 ? ErikaImageSuccess(@{}) : ErikaImageFailure(status);
}

+ (NSDictionary<NSString *, id> *)cancelWithOperationId:(uint64_t)operationId {
  int32_t status = erika_image_cancel_decode(operationId);
  return status == 0 ? ErikaImageSuccess(@{}) : ErikaImageFailure(status);
}

@end
