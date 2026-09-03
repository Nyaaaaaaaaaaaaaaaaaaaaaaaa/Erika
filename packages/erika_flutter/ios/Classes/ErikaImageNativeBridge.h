#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Narrow Objective-C bridge around Erika's decode-once image C ABI.
///
/// Keeping the by-value C structs on the Objective-C side avoids duplicating
/// their calling convention in Swift while the Flutter plugin remains free to
/// schedule all calls away from the main thread.
@interface ErikaImageNativeBridge : NSObject

+ (NSDictionary<NSString *, id> *)decodeWithOperationId:(uint64_t)operationId
                                                    path:(NSString *)path
                                                maxWidth:(uint32_t)maxWidth
                                               maxHeight:(uint32_t)maxHeight
                                         maxEncodedBytes:(uint64_t)maxEncodedBytes
                                         maxSourcePixels:(uint64_t)maxSourcePixels
                                         maxOutputPixels:(uint64_t)maxOutputPixels
                               maxPacketsBeforeFrame:(uint32_t)maxPacketsBeforeFrame
                                decodeTimeoutMillis:(uint64_t)decodeTimeoutMillis
    NS_SWIFT_NAME(decode(operationId:path:maxWidth:maxHeight:maxEncodedBytes:maxSourcePixels:maxOutputPixels:maxPacketsBeforeFrame:decodeTimeoutMillis:));
+ (NSDictionary<NSString *, id> *)renderSdrWithHandle:(uint64_t)handle
                                              maxWidth:(uint32_t)maxWidth
                                             maxHeight:(uint32_t)maxHeight
    NS_SWIFT_NAME(renderSdr(handle:maxWidth:maxHeight:));
+ (NSDictionary<NSString *, id> *)attachSurfaceWithHandle:(uint64_t)handle
                                               metalLayer:(void *)metalLayer
                                                    width:(uint32_t)width
                                                   height:(uint32_t)height
                                                    scale:(double)scale
                                           extendedLinear:(BOOL)extendedLinear
                                        directComposition:(BOOL)directComposition
                                          desiredHeadroom:(float)desiredHeadroom
                                           fallbackReason:(int32_t)fallbackReason
    NS_SWIFT_NAME(attachSurface(handle:metalLayer:width:height:scale:extendedLinear:directComposition:desiredHeadroom:fallbackReason:));
+ (NSDictionary<NSString *, id> *)resizeSurfaceWithHandle:(uint64_t)handle
                                                    width:(uint32_t)width
                                                   height:(uint32_t)height
                                                    scale:(double)scale
    NS_SWIFT_NAME(resizeSurface(handle:width:height:scale:));
+ (NSDictionary<NSString *, id> *)renderSurfaceWithHandle:(uint64_t)handle
    NS_SWIFT_NAME(renderSurface(handle:));
+ (NSDictionary<NSString *, id> *)detachSurfaceWithHandle:(uint64_t)handle
    NS_SWIFT_NAME(detachSurface(handle:));
+ (NSDictionary<NSString *, id> *)destroyWithHandle:(uint64_t)handle
    NS_SWIFT_NAME(destroy(handle:));
+ (NSDictionary<NSString *, id> *)cancelWithOperationId:(uint64_t)operationId
    NS_SWIFT_NAME(cancel(operationId:));

@end

NS_ASSUME_NONNULL_END
