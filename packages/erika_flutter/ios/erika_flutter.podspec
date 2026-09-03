Pod::Spec.new do |s|
  erika_cabi_symbols = %w[
    erika_danmaku_track_info_free
    erika_presenter_add_danmaku_track_file
    erika_presenter_add_danmaku_track_json
    erika_presenter_add_external_subtitle
    erika_presenter_attach_metal_layer
    erika_presenter_clear_danmaku
    erika_presenter_close
    erika_presenter_create
    erika_presenter_create_with_output_mode
    erika_presenter_danmaku_tracks
    erika_presenter_destroy
    erika_presenter_detach_surface
    erika_presenter_get_danmaku_config
    erika_presenter_get_upscaler_status
    erika_presenter_load_danmaku_file
    erika_presenter_load_danmaku_json
    erika_presenter_open
    erika_presenter_open_with_headers
    erika_presenter_pause
    erika_presenter_play
    erika_presenter_poll_event
    erika_presenter_remove_danmaku_track
    erika_presenter_remove_subtitle_track
    erika_presenter_register_subtitle_memory_font
    erika_presenter_render_tick
    erika_presenter_resize_surface
    erika_presenter_seek
    erika_presenter_select_audio_track
    erika_presenter_select_subtitle_track
    erika_presenter_select_subtitle_memory_fonts
    erika_presenter_clear_subtitle_memory_fonts
    erika_presenter_get_subtitle_memory_font_status
    erika_presenter_set_danmaku_block_words_json
    erika_presenter_set_danmaku_config_ptr
    erika_presenter_set_danmaku_enabled
    erika_presenter_set_danmaku_font
    erika_presenter_set_danmaku_global_offset
    erika_presenter_set_danmaku_track_enabled
    erika_presenter_set_danmaku_track_offset
    erika_presenter_set_playback_rate
    erika_presenter_set_subtitle_scale
    erika_presenter_set_upscaler
    erika_presenter_set_volume
    erika_presenter_stop
    erika_presenter_track_selection
    erika_presenter_tracks
    erika_image_attach_wgpu_surface
    erika_image_cancel_decode
    erika_image_decode_uri
    erika_image_decode_uri_sized
    erika_image_decode_uri_sized_with_policy
    erika_image_destroy
    erika_image_detach_surface
    erika_image_get_metadata
    erika_image_last_error_kind
    erika_image_render_sdr_rgba
    erika_image_render_surface
    erika_image_resize_surface
    erika_image_rgba_free
    erika_track_info_free
    erika_subtitle_memory_font_status_free
  ]
  erika_cabi_undefined_flags = erika_cabi_symbols
    .map { |symbol| "-Wl,-u,_#{symbol}" }
    .join(' ')
  erika_link_flags = "$(inherited) #{erika_cabi_undefined_flags} -framework AVFoundation -framework AudioToolbox -framework QuartzCore -framework Metal -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework CoreText -framework CoreFoundation -framework CoreGraphics -framework Foundation -liconv -lbz2 -lz"

  s.name             = 'erika_flutter'
  s.version          = '0.2.0'
  s.summary          = 'Flutter embedder glue for the Erika Rust media engine.'
  s.description      = <<-DESC
Flutter iOS AV1/static AVIF plugin that hosts a CAMetalLayer and drives Erika through its C ABI.
                       DESC
  s.homepage         = 'https://github.com/Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika'
  s.license          = { :type => 'MPL-2.0' }
  s.author           = { 'AimesSoft' => 'dev@aimesoft.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.static_framework = true
  s.vendored_libraries = 'native/liberika_capi.a'
  s.preserve_paths   = 'native/liberika_capi.a'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.script_phase = {
    :name => 'Build Erika C ABI',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/erika_capi_phony'],
    :output_files => ['${PODS_TARGET_SRCROOT}/native/liberika_capi.a'],
    :script => <<-SCRIPT
set -eu

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

PLUGIN_IOS_DIR="$(cd "$PODS_TARGET_SRCROOT" && pwd -P)"
PACKAGE_ROOT="$(cd "$PLUGIN_IOS_DIR/.." && pwd -P)"
OUTPUT_LIB="$PODS_TARGET_SRCROOT/native/liberika_capi.a"
ERIKA_NATIVE_PROFILE="${ERIKA_NATIVE_PROFILE:-lgpl}"
HOST_JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
ARCH="${CURRENT_ARCH:-}"
if [ -z "$ARCH" ] || [ "$ARCH" = "undefined_arch" ]; then
  ARCH="${ARCHS%% *}"
fi

case "${PLATFORM_NAME:-iphoneos}" in
  iphoneos)
    RUST_TARGETS="aarch64-apple-ios"
    BINDGEN_SDK="iphoneos"
    ;;
  iphonesimulator)
    RUST_TARGETS="aarch64-apple-ios-sim x86_64-apple-ios"
    BINDGEN_SDK="iphonesimulator"
    ;;
  *)
    echo "error: unsupported Erika iOS platform: ${PLATFORM_NAME:-unknown}" >&2
    exit 1
    ;;
esac

if [ -n "${ERIKA_IOS_CAPI_PROFILE:-}" ]; then
  CARGO_PROFILE="$ERIKA_IOS_CAPI_PROFILE"
elif [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  CARGO_PROFILE="release"
else
  CARGO_PROFILE="debug"
fi
if [ "$CARGO_PROFILE" = "release" ]; then
  CARGO_ARGS="--release"
elif [ "$CARGO_PROFILE" = "debug" ]; then
  CARGO_ARGS=""
else
  echo "error: unsupported ERIKA_IOS_CAPI_PROFILE=$CARGO_PROFILE" >&2
  exit 1
fi

mkdir -p "$PODS_TARGET_SRCROOT/native"
if [ -n "${ERIKA_IOS_CAPI_STATICLIB:-}" ]; then
  cp "$ERIKA_IOS_CAPI_STATICLIB" "$OUTPUT_LIB"
elif [ "${ERIKA_FORCE_SOURCE_BUILD:-0}" != "1" ]; then
  sh "$PACKAGE_ROOT/native/prepare_apple_prebuilt.sh"     ios "${PLATFORM_NAME:-iphoneos}" "$ARCH" "$OUTPUT_LIB"
else
  if [ -n "${ERIKA_REPO_ROOT:-}" ]; then
    SOURCE_ROOT="$ERIKA_REPO_ROOT"
  elif [ -n "${ERIKA_ROOT:-}" ]; then
    SOURCE_ROOT="$ERIKA_ROOT"
  else
    SOURCE_ROOT="$(cd "$PACKAGE_ROOT/../.." && pwd -P)"
  fi
  if [ ! -f "$SOURCE_ROOT/crates/erika_capi/Cargo.toml" ]; then
    echo "error: ERIKA_FORCE_SOURCE_BUILD=1 requires an Erika checkout; set ERIKA_REPO_ROOT" >&2
    exit 1
  fi
  if command -v rustup >/dev/null 2>&1; then
    rustup target add $RUST_TARGETS
  fi
  BINDGEN_SDKROOT="$(xcrun --sdk "$BINDGEN_SDK" --show-sdk-path)"
  ERIKA_FFMPEG_OVERRIDE="${ERIKA_FFMPEG_DIR:-}"
  ERIKA_DAV1D_OVERRIDE="${ERIKA_DAV1D_DIR:-}"
  LIPO_INPUTS=""

  for RUST_TARGET in $RUST_TARGETS; do
    case "$RUST_TARGET" in
      aarch64-apple-ios) BINDGEN_CLANG_TARGET="arm64-apple-ios" ;;
      aarch64-apple-ios-sim) BINDGEN_CLANG_TARGET="arm64-apple-ios-simulator" ;;
      x86_64-apple-ios) BINDGEN_CLANG_TARGET="x86_64-apple-ios-simulator" ;;
    esac
    BINDGEN_TARGET_ENV="$(echo "$RUST_TARGET" | tr '-' '_')"
    export "BINDGEN_EXTRA_CLANG_ARGS_$BINDGEN_TARGET_ENV=--target=$BINDGEN_CLANG_TARGET -isysroot $BINDGEN_SDKROOT"

    ERIKA_TARGET_DIST="$SOURCE_ROOT/third_party/dist/$RUST_TARGET/$ERIKA_NATIVE_PROFILE"
    TARGET_FFMPEG_DIR="${ERIKA_FFMPEG_OVERRIDE:-$ERIKA_TARGET_DIST/ffmpeg}"
    TARGET_DAV1D_DIR="${ERIKA_DAV1D_OVERRIDE:-$ERIKA_TARGET_DIST/dav1d}"
    ERIKA_DAV1D_MARKER="$SOURCE_ROOT/third_party/build/$RUST_TARGET/$ERIKA_NATIVE_PROFILE/dav1d/dav1d-built.txt"

    if [ ! -f "$TARGET_FFMPEG_DIR/include/libavformat/avformat.h" ] || [ ! -f "$TARGET_DAV1D_DIR/include/dav1d/dav1d.h" ] || [ ! -f "$TARGET_DAV1D_DIR/lib/libdav1d.a" ] || [ ! -f "$ERIKA_DAV1D_MARKER" ] || ! grep -qx 'dav1d=1.5.1' "$ERIKA_DAV1D_MARKER"; then
      (cd "$SOURCE_ROOT" && cargo run -p xtask -- deps build --profile "$ERIKA_NATIVE_PROFILE" --target "$RUST_TARGET" --jobs "$HOST_JOBS")
    fi
    (cd "$SOURCE_ROOT" && ERIKA_NATIVE_PROFILE="$ERIKA_NATIVE_PROFILE" ERIKA_NATIVE_TARGET="$RUST_TARGET" ERIKA_FFMPEG_DIR="$TARGET_FFMPEG_DIR" ERIKA_DAV1D_DIR="$TARGET_DAV1D_DIR" cargo rustc -p erika_capi --target "$RUST_TARGET" --no-default-features --features wgpu $CARGO_ARGS --lib --crate-type staticlib)
    LIPO_INPUTS="$LIPO_INPUTS $SOURCE_ROOT/target/$RUST_TARGET/$CARGO_PROFILE/liberika_capi.a"
  done

  set -- $LIPO_INPUTS
  if [ "$#" -eq 1 ]; then
    cp "$1" "$OUTPUT_LIB"
  else
    xcrun lipo -create "$@" -output "$OUTPUT_LIB"
  fi
fi

if [ ! -f "$OUTPUT_LIB" ]; then
  echo "error: Erika C ABI static library not found: $OUTPUT_LIB" >&2
  exit 1
fi
for ERIKA_IMAGE_SYMBOL in \
  erika_image_attach_wgpu_surface \
  erika_image_cancel_decode \
  erika_image_decode_uri \
  erika_image_decode_uri_sized \
  erika_image_decode_uri_sized_with_policy \
  erika_image_destroy \
  erika_image_detach_surface \
  erika_image_get_metadata \
  erika_image_last_error_kind \
  erika_image_render_sdr_rgba \
  erika_image_render_surface \
  erika_image_resize_surface \
  erika_image_rgba_free
do
  if ! xcrun nm -gU "$OUTPUT_LIB" | grep -q "_$ERIKA_IMAGE_SYMBOL"; then
    echo "error: Erika iOS runtime is missing $ERIKA_IMAGE_SYMBOL" >&2
    exit 1
  fi
done
OUTPUT_ARCHS="$(xcrun lipo -archs "$OUTPUT_LIB")"
case " $OUTPUT_ARCHS " in
  *" arm64 "*) ;;
  *) echo "error: Erika iOS runtime is missing arm64: $OUTPUT_ARCHS" >&2; exit 1 ;;
esac
if [ "${PLATFORM_NAME:-iphoneos}" = "iphonesimulator" ]; then
  case " $OUTPUT_ARCHS " in
    *" x86_64 "*) ;;
    *) echo "error: Erika iOS simulator runtime is missing x86_64: $OUTPUT_ARCHS" >&2; exit 1 ;;
  esac
fi
if [ -f "$OBJROOT/XCBuildData/build.db" ]; then
  ln -fs "$OBJROOT/XCBuildData/build.db" "$BUILT_PRODUCTS_DIR/erika_capi_phony"
fi
    SCRIPT
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => erika_link_flags,
  }
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => erika_link_flags,
  }
end
