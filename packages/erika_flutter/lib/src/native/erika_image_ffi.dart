import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../erika_image.dart';

int allocateErikaImageOperationId() {
  final id = _erikaLibrary()
      .lookupFunction<ffi.Uint64 Function(), int Function()>(
        'erika_image_allocate_operation_id',
      )();
  if (id == 0) {
    throw const ErikaImageException(
      ErikaImageErrorReason.resourceLimit,
      'Erika image operation ID space is exhausted',
    );
  }
  return id;
}

void cancelErikaImageDecode(int operationId) {
  final cancel = _erikaLibrary()
      .lookupFunction<ffi.Int32 Function(ffi.Uint64), int Function(int)>(
        'erika_image_cancel_decode',
      );
  cancel(operationId);
}

Map<String, Object> decodeErikaSdrInWorker(
  String path,
  int maximumDecodeExtent,
  int operationId,
  ErikaImagePolicy imagePolicy,
) {
  final library = _erikaLibrary();
  final decode = library.lookupFunction<_DecodeNative, _DecodeDart>(
    'erika_image_decode_uri_sized_with_policy',
  );
  final render = library.lookupFunction<_RenderNative, _RenderDart>(
    'erika_image_render_sdr_rgba',
  );
  final freeRgba = library.lookupFunction<_FreeRgbaNative, _FreeRgbaDart>(
    'erika_image_rgba_free',
  );
  final destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
    'erika_image_destroy',
  );
  final imageErrorKind = library
      .lookupFunction<_ImageErrorKindNative, _ImageErrorKindDart>(
        'erika_image_last_error_kind',
      );
  final lastError = library.lookupFunction<_LastErrorNative, _LastErrorDart>(
    'erika_last_error_message',
  );
  final freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
    'erika_string_free',
  );

  final pathPointer = path.toNativeUtf8();
  final policy = calloc<_ErikaImageDecodePolicy>();
  final handle = calloc<ffi.Uint64>();
  final rgba = calloc<_ErikaImageRgba>();
  var rgbaOwned = false;
  try {
    policy.ref
      ..maxInputBytes = imagePolicy.maxEncodedBytes
      ..maxSourcePixels = imagePolicy.maxSourcePixels
      ..maxOutputPixels = imagePolicy.maxOutputPixels
      ..maxPacketsBeforeFrame = imagePolicy.maxPacketsBeforeFrame
      ..decodeTimeoutMillis = imagePolicy.decodeTimeout.inMilliseconds;
    final decodeStatus = decode(
      operationId,
      pathPointer,
      ffi.nullptr,
      maximumDecodeExtent,
      maximumDecodeExtent,
      policy,
      handle,
    );
    if (decodeStatus != 0) {
      throw ErikaImageException(
        _nativeErrorReason(imageErrorKind()),
        _readNativeError(lastError, freeString),
      );
    }
    final renderStatus = render(
      handle.value,
      maximumDecodeExtent,
      maximumDecodeExtent,
      rgba,
    );
    if (renderStatus != 0) {
      throw ErikaImageException(
        _nativeErrorReason(imageErrorKind()),
        _readNativeError(lastError, freeString),
      );
    }
    rgbaOwned = true;
    final layout = rgba.ref.layout;
    if (rgba.ref.data == ffi.nullptr ||
        layout.width <= 0 ||
        layout.height <= 0 ||
        layout.width > maximumDecodeExtent ||
        layout.height > maximumDecodeExtent ||
        layout.rowBytes < layout.width * 4 ||
        layout.byteLength < layout.rowBytes * layout.height ||
        layout.byteLength > imagePolicy.maxOutputPixels * 4) {
      throw const ErikaImageException(
        ErikaImageErrorReason.internal,
        'Erika returned an invalid SDR pixel layout',
      );
    }
    return <String, Object>{
      'width': layout.width,
      'height': layout.height,
      'rowBytes': layout.rowBytes,
      // TransferableTypedData copies while native RGBA is still owned here;
      // free it only after the transfer buffer has been populated.
      'bytes': TransferableTypedData.fromList(<Uint8List>[
        rgba.ref.data.asTypedList(layout.byteLength),
      ]),
    };
  } finally {
    if (rgbaOwned) freeRgba(rgba);
    if (handle.value != 0) destroy(handle.value);
    calloc
      ..free(rgba)
      ..free(handle)
      ..free(policy)
      ..free(pathPointer);
  }
}

ffi.DynamicLibrary _erikaLibrary() => Platform.isIOS
    ? ffi.DynamicLibrary.process()
    : ffi.DynamicLibrary.open('liberika_capi.so');

String _readNativeError(_LastErrorDart read, _FreeStringDart free) {
  final value = read();
  if (value == ffi.nullptr) return 'unknown error';
  try {
    return value.toDartString();
  } finally {
    free(value);
  }
}

final class _ErikaImageDecodePolicy extends ffi.Struct {
  @ffi.Uint64()
  external int maxInputBytes;

  @ffi.Uint64()
  external int maxSourcePixels;

  @ffi.Uint64()
  external int maxOutputPixels;

  @ffi.Uint32()
  external int maxPacketsBeforeFrame;

  @ffi.Uint64()
  external int decodeTimeoutMillis;
}

final class _ErikaImageRgbaLayout extends ffi.Struct {
  @ffi.Uint32()
  external int width;

  @ffi.Uint32()
  external int height;

  @ffi.Uint32()
  external int rowBytes;

  @ffi.UintPtr()
  external int byteLength;
}

final class _ErikaImageRgba extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> data;
  external _ErikaImageRgbaLayout layout;
}

typedef _DecodeNative =
    ffi.Int32 Function(
      ffi.Uint64 operationId,
      ffi.Pointer<Utf8> uri,
      ffi.Pointer<ffi.Void> options,
      ffi.Uint32 maxWidth,
      ffi.Uint32 maxHeight,
      ffi.Pointer<_ErikaImageDecodePolicy> policy,
      ffi.Pointer<ffi.Uint64> handle,
    );
typedef _DecodeDart =
    int Function(
      int operationId,
      ffi.Pointer<Utf8> uri,
      ffi.Pointer<ffi.Void> options,
      int maxWidth,
      int maxHeight,
      ffi.Pointer<_ErikaImageDecodePolicy> policy,
      ffi.Pointer<ffi.Uint64> handle,
    );
typedef _RenderNative =
    ffi.Int32 Function(
      ffi.Uint64 handle,
      ffi.Uint32 maxWidth,
      ffi.Uint32 maxHeight,
      ffi.Pointer<_ErikaImageRgba> rgba,
    );
typedef _RenderDart =
    int Function(
      int handle,
      int maxWidth,
      int maxHeight,
      ffi.Pointer<_ErikaImageRgba> rgba,
    );
typedef _FreeRgbaNative = ffi.Void Function(ffi.Pointer<_ErikaImageRgba> rgba);
typedef _FreeRgbaDart = void Function(ffi.Pointer<_ErikaImageRgba> rgba);
typedef _DestroyNative = ffi.Int32 Function(ffi.Uint64 handle);
typedef _DestroyDart = int Function(int handle);
typedef _ImageErrorKindNative = ffi.Int32 Function();
typedef _ImageErrorKindDart = int Function();
typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<Utf8> value);
typedef _FreeStringDart = void Function(ffi.Pointer<Utf8> value);
ErikaImageErrorReason _nativeErrorReason(int kind) => switch (kind) {
  1 => ErikaImageErrorReason.unsupportedPlatform,
  2 => ErikaImageErrorReason.unsupportedFormat,
  3 => ErikaImageErrorReason.corrupt,
  4 => ErikaImageErrorReason.source,
  5 => ErikaImageErrorReason.network,
  6 => ErikaImageErrorReason.cancelled,
  7 => ErikaImageErrorReason.resourceLimit,
  8 => ErikaImageErrorReason.renderer,
  10 => ErikaImageErrorReason.busy,
  _ => ErikaImageErrorReason.internal,
};
