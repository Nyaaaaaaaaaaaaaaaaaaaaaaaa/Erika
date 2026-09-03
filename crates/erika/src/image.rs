//! Decode-once still-image pipeline.
//!
//! This module deliberately does not create a [`crate::Player`]. Static AVIF
//! images are demuxed and decoded once, then either rendered into a bounded SDR
//! RGBA buffer or retained as 8/10-bit YUV planes for a native HDR surface.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "wgpu")]
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use thiserror::Error;

use crate::core::{ColorPrimaries, MediaRequest, MediaSourceHint, TransferFunction};
#[cfg(feature = "wgpu")]
use crate::core::{PlatformSurface, RenderFrameContext, RendererBackend, SurfaceMetrics};
use crate::ffmpeg::{
    Decoder, DecoderConfig, DecoderOutputFrame, Demuxer, PlanarFrame, PlanarPixelFormat,
    StreamSelection,
};
use crate::renderer::output::DynamicRange;
#[cfg(feature = "wgpu")]
use crate::renderer::output::{OutputMode, OutputRuntimeStatus};
use crate::renderer::pipeline::{ColorRange, MatrixCoefficients, SourceColorState};
#[cfg(feature = "wgpu")]
use crate::renderer::wgpu::WgpuRenderer;
use crate::source::source_from_uri_with_options;

pub const MAX_IMAGE_INPUT_BYTES: u64 = 128 * 1024 * 1024;
pub const MAX_IMAGE_SOURCE_PIXELS: u64 = 32 * 1024 * 1024;
pub const MAX_IMAGE_OUTPUT_PIXELS: u64 = 32 * 1024 * 1024;
pub const MAX_IMAGE_PACKETS_BEFORE_FRAME: usize = 4_096;
pub const MAX_IMAGE_DECODE_TIME: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageDecodePolicy {
    pub max_input_bytes: u64,
    pub max_source_pixels: u64,
    pub max_output_pixels: u64,
    pub max_packets_before_frame: usize,
    pub decode_timeout: Duration,
}

impl Default for ImageDecodePolicy {
    fn default() -> Self {
        Self {
            max_input_bytes: MAX_IMAGE_INPUT_BYTES,
            max_source_pixels: MAX_IMAGE_SOURCE_PIXELS,
            max_output_pixels: MAX_IMAGE_OUTPUT_PIXELS,
            max_packets_before_frame: 256,
            decode_timeout: Duration::from_secs(15),
        }
    }
}

impl ImageDecodePolicy {
    fn validate(self) -> Result<Self> {
        if self.max_input_bytes == 0 || self.max_input_bytes > MAX_IMAGE_INPUT_BYTES {
            return Err(ImageError::WorkLimit(format!(
                "max input bytes must be within 1..={MAX_IMAGE_INPUT_BYTES}"
            )));
        }
        if self.max_source_pixels == 0 || self.max_source_pixels > MAX_IMAGE_SOURCE_PIXELS {
            return Err(ImageError::WorkLimit(format!(
                "max source pixels must be within 1..={MAX_IMAGE_SOURCE_PIXELS}"
            )));
        }
        if self.max_output_pixels == 0 || self.max_output_pixels > MAX_IMAGE_OUTPUT_PIXELS {
            return Err(ImageError::WorkLimit(format!(
                "max output pixels must be within 1..={MAX_IMAGE_OUTPUT_PIXELS}"
            )));
        }
        if self.max_packets_before_frame == 0
            || self.max_packets_before_frame > MAX_IMAGE_PACKETS_BEFORE_FRAME
        {
            return Err(ImageError::WorkLimit(format!(
                "max packets before frame must be within 1..={MAX_IMAGE_PACKETS_BEFORE_FRAME}"
            )));
        }
        if self.decode_timeout.is_zero() || self.decode_timeout > MAX_IMAGE_DECODE_TIME {
            return Err(ImageError::WorkLimit(format!(
                "decode timeout must be within 1ms..={}s",
                MAX_IMAGE_DECODE_TIME.as_secs()
            )));
        }
        Ok(self)
    }
}

#[derive(Debug, Error)]
pub enum ImageError {
    #[error("image source error: {0}")]
    Source(String),
    #[error("image demux error: {0}")]
    Demux(String),
    #[error("image has no visual track")]
    NoVisualTrack,
    #[error("image decoder error: {0}")]
    Decode(String),
    #[error("image contains no decodable frame")]
    NoFrame,
    #[error("unsupported decoded image pixel format")]
    UnsupportedPixelFormat,
    #[error("image decode was cancelled")]
    Cancelled,
    #[error("image decode exceeded its bounded work budget: {0}")]
    WorkLimit(String),
    #[error("image dimensions {width}x{height} exceed the {max_pixels}-pixel safety limit")]
    PixelLimit {
        width: u32,
        height: u32,
        max_pixels: u64,
    },
    #[error("image renderer error: {0}")]
    Renderer(String),
}

pub type Result<T> = std::result::Result<T, ImageError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImagePixelFormat {
    Rgba8888,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageMetadata {
    pub width: u32,
    pub height: u32,
    pub bit_depth: u8,
    pub primaries: ColorPrimaries,
    pub transfer: TransferFunction,
    pub matrix: MatrixCoefficients,
    pub range: ColorRange,
    pub source_dynamic_range: DynamicRange,
    /// Static-image v1 deliberately uses the CPU-readable software AV1
    /// decoder. This keeps MediaCodec/Surface lifecycle out of decode-once.
    pub decode_backend: crate::ffmpeg::DecoderBackend,
}

impl ImageMetadata {
    pub fn is_hdr(self) -> bool {
        matches!(
            self.source_dynamic_range,
            DynamicRange::Hdr10Pq | DynamicRange::Hlg | DynamicRange::UltraHdrGainMap
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SdrImage {
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
    pub pixel_format: ImagePixelFormat,
    pub rgba: Vec<u8>,
}

pub struct DecodedImage {
    metadata: ImageMetadata,
    planes: Option<PlanarFrame>,
    source_color: SourceColorState,
    max_output_pixels: u64,
    #[cfg(feature = "wgpu")]
    surface_renderer: Option<WgpuRenderer>,
}

impl DecodedImage {
    pub fn decode(request: &MediaRequest) -> Result<Self> {
        Self::decode_with_cancel(request, &AtomicBool::new(false))
    }

    pub fn decode_with_cancel(request: &MediaRequest, cancelled: &AtomicBool) -> Result<Self> {
        Self::decode_with_cancel_and_max_extent(request, cancelled, 0, 0)
    }

    /// Decode one source frame while bounding the retained upload planes.
    ///
    /// The decoder must still materialize the encoded source frame, but a small
    /// card no longer keeps a full-resolution repack alive for the later WGPU
    /// upload. Zero dimensions preserve the historical full-source behaviour.
    pub fn decode_with_cancel_and_max_extent(
        request: &MediaRequest,
        cancelled: &AtomicBool,
        max_width: u32,
        max_height: u32,
    ) -> Result<Self> {
        Self::decode_with_cancel_and_max_extent_and_policy(
            request,
            cancelled,
            max_width,
            max_height,
            ImageDecodePolicy::default(),
        )
    }

    pub fn decode_with_cancel_and_max_extent_and_policy(
        request: &MediaRequest,
        cancelled: &AtomicBool,
        max_width: u32,
        max_height: u32,
        policy: ImageDecodePolicy,
    ) -> Result<Self> {
        let policy = policy.validate()?;
        let started = Instant::now();
        if request.source_hint == MediaSourceHint::Http
            || request.uri.starts_with("http://")
            || request.uri.starts_with("https://")
        {
            return Err(ImageError::Source(
                "static image decode accepts only a cached local file or owned fd".to_string(),
            ));
        }
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "before source open",
        )?;
        let mut source = source_from_uri_with_options(
            &request.uri,
            MediaSourceHint::LocalFile,
            Vec::new(),
            None,
        )
        .map_err(|error| ImageError::Source(error.to_string()))?;
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "after source open",
        )?;
        if let Some(input_bytes) = source
            .len()
            .map_err(|error| ImageError::Source(error.to_string()))?
            && input_bytes > policy.max_input_bytes
        {
            return Err(ImageError::WorkLimit(format!(
                "encoded image is {input_bytes} bytes, exceeding the {}-byte policy limit",
                policy.max_input_bytes
            )));
        }
        let mut demuxer =
            Demuxer::open_source(source).map_err(|error| ImageError::Demux(error.to_string()))?;
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "after demux open",
        )?;
        let visual = demuxer
            .probe()
            .video
            .first()
            .cloned()
            .ok_or(ImageError::NoVisualTrack)?;
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "after stream probe",
        )?;
        if visual.params.width > 0 && visual.params.height > 0 {
            validate_pixels(
                visual.params.width,
                visual.params.height,
                policy.max_source_pixels,
            )?;
        }
        let stream_index = i32::try_from(visual.track_id).map_err(|_| {
            ImageError::Decode(format!(
                "visual track id {} does not fit i32",
                visual.track_id
            ))
        })?;
        demuxer
            .set_stream_selection(StreamSelection::Only(BTreeSet::from([stream_index])))
            .map_err(|error| ImageError::Demux(error.to_string()))?;
        let parameters = demuxer
            .owned_codec_parameters(stream_index)
            .map_err(|error| ImageError::Decode(error.to_string()))?;
        // Still images need CPU-readable planes. A hardware Surface decoder
        // would add lifecycle and buffer-queue state without accelerating the
        // single-frame presentation contract.
        let mut decoder = Decoder::open_owned_with_config(&parameters, DecoderConfig::software())
            .map_err(|error| ImageError::Decode(error.to_string()))?;
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "after decoder open",
        )?;
        let frame = decode_first_frame(&mut demuxer, &mut decoder, cancelled, started, policy)?;
        let width = u32::try_from(frame.width()).unwrap_or(0);
        let height = u32::try_from(frame.height()).unwrap_or(0);
        validate_pixels(width, height, policy.max_source_pixels)?;
        let frame_primaries = frame.color_primaries();
        let frame_transfer = frame.transfer_function();
        let primaries = if frame_primaries == ColorPrimaries::Unknown {
            visual.params.primaries
        } else {
            frame_primaries
        };
        let transfer = if frame_transfer == TransferFunction::Unknown {
            visual.params.transfer
        } else {
            frame_transfer
        };
        let source_color = SourceColorState::new(primaries, transfer)
            .matrix(frame.matrix_coefficients())
            .range(frame.color_range())
            .hdr_metadata(frame.hdr_metadata());
        let retained_extent = bounded_extent(width, height, max_width, max_height);
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "before static image repack",
        )?;
        let planes = frame
            .to_planar_frame_sized(retained_extent.0, retained_extent.1)
            .ok_or(ImageError::UnsupportedPixelFormat)?;
        ensure_active(
            cancelled,
            started,
            policy.decode_timeout,
            "after static image repack",
        )?;
        let bit_depth = match planes.format {
            PlanarPixelFormat::Nv12 => 8,
            PlanarPixelFormat::P010 => 10,
        };
        let source_dynamic_range = match source_color.transfer {
            TransferFunction::Pq => DynamicRange::Hdr10Pq,
            TransferFunction::Hlg => DynamicRange::Hlg,
            TransferFunction::Srgb | TransferFunction::Bt1886 => DynamicRange::Sdr,
            TransferFunction::Unknown => DynamicRange::Unknown,
        };
        Ok(Self {
            metadata: ImageMetadata {
                width,
                height,
                bit_depth,
                primaries: source_color.primaries,
                transfer: source_color.transfer,
                matrix: source_color.matrix,
                range: source_color.range,
                source_dynamic_range,
                decode_backend: crate::ffmpeg::DecoderBackend::Software,
            },
            planes: Some(planes),
            source_color,
            max_output_pixels: policy.max_output_pixels,
            #[cfg(feature = "wgpu")]
            surface_renderer: None,
        })
    }

    pub fn metadata(&self) -> ImageMetadata {
        self.metadata
    }

    /// Tone-map/gamut-map the complete decoded image into a tightly packed SDR
    /// RGBA8888 buffer. `max_width`/`max_height` are pixel bounds, not a crop.
    #[cfg(feature = "wgpu")]
    pub fn render_sdr(&mut self, max_width: u32, max_height: u32) -> Result<SdrImage> {
        let (width, height) = bounded_extent(
            self.metadata.width,
            self.metadata.height,
            max_width,
            max_height,
        );
        validate_pixels(width, height, self.max_output_pixels)?;
        let output_bytes = u64::from(width)
            .saturating_mul(u64::from(height))
            .saturating_mul(4);
        if output_bytes > self.max_output_pixels.saturating_mul(4) {
            return Err(ImageError::PixelLimit {
                width,
                height,
                max_pixels: self.max_output_pixels,
            });
        }
        let planes = self.planes.take().ok_or_else(|| {
            ImageError::Renderer("decoded image pixels were already consumed".to_string())
        })?;
        let readback = with_shared_sdr_renderer(|renderer| {
            renderer.upload_static_planar(planes, self.source_color, false)?;
            renderer
                .render_current_offscreen_sized_for_image(width, height)?
                .ok_or_else(|| {
                    crate::PlayerError::Renderer("renderer retained no image frame".to_string())
                })
        })?;
        Ok(SdrImage {
            width: readback.width,
            height: readback.height,
            row_bytes: readback.width.saturating_mul(4),
            pixel_format: ImagePixelFormat::Rgba8888,
            rgba: readback.rgba,
        })
    }

    pub fn validate_output_extent(&self, width: u32, height: u32) -> Result<()> {
        validate_pixels(width, height, self.max_output_pixels)
    }

    /// Attach a native surface and move the 8/10-bit source planes into its
    /// dedicated still renderer. HDR is
    /// reported only after the renderer has actually presented to an HDR/EDR
    /// surface; an SDR surface automatically receives a full-source tone-map.
    #[cfg(feature = "wgpu")]
    pub fn attach_surface(&mut self, surface: PlatformSurface) -> Result<()> {
        if let Some(renderer) = self.surface_renderer.as_mut() {
            return renderer
                .attach_surface(surface)
                .map_err(|error| ImageError::Renderer(error.to_string()));
        }
        let output_mode = if self.metadata.is_hdr() {
            OutputMode::extended_linear(4.0)
        } else {
            OutputMode::Sdr
        };
        let mut renderer = WgpuRenderer::new_with_output_mode(output_mode)
            .map_err(|error| ImageError::Renderer(error.to_string()))?;
        renderer
            .attach_surface(surface)
            .map_err(|error| ImageError::Renderer(error.to_string()))?;
        let planes = self.planes.take().ok_or_else(|| {
            ImageError::Renderer("decoded image pixels were already consumed".to_string())
        })?;
        renderer
            .upload_static_planar(planes, self.source_color, false)
            .map_err(|error| ImageError::Renderer(error.to_string()))?;
        self.surface_renderer = Some(renderer);
        Ok(())
    }

    #[cfg(feature = "wgpu")]
    pub fn resize_surface(&mut self, metrics: SurfaceMetrics) -> Result<()> {
        let renderer = self.surface_renderer.as_mut().ok_or_else(|| {
            ImageError::Renderer("cannot resize before image surface attach".to_string())
        })?;
        renderer
            .resize_surface(metrics)
            .map_err(|error| ImageError::Renderer(error.to_string()))
    }

    #[cfg(feature = "wgpu")]
    pub fn render_surface(&mut self) -> Result<OutputRuntimeStatus> {
        let renderer = self.surface_renderer.as_mut().ok_or_else(|| {
            ImageError::Renderer("cannot render before image surface attach".to_string())
        })?;
        renderer
            .render_current_frame(RenderFrameContext::new(std::time::Duration::ZERO, 1))
            .map_err(|error| ImageError::Renderer(error.to_string()))?;
        Ok(renderer.output_status())
    }

    #[cfg(feature = "wgpu")]
    pub fn detach_surface(&mut self) -> Result<()> {
        if let Some(renderer) = self.surface_renderer.as_mut() {
            renderer
                .detach_surface()
                .map_err(|error| ImageError::Renderer(error.to_string()))?;
        }
        Ok(())
    }
}

#[cfg(feature = "wgpu")]
fn with_shared_sdr_renderer<T>(
    operation: impl FnOnce(&mut WgpuRenderer) -> crate::Result<T>,
) -> Result<T> {
    static RENDERER: OnceLock<Mutex<Option<WgpuRenderer>>> = OnceLock::new();
    let renderer = RENDERER.get_or_init(|| Mutex::new(None));
    let mut renderer = renderer
        .lock()
        .map_err(|_| ImageError::Renderer("shared SDR renderer lock was poisoned".to_string()))?;
    if renderer.is_none() {
        *renderer = Some(
            WgpuRenderer::new_with_output_mode(OutputMode::Sdr)
                .map_err(|error| ImageError::Renderer(error.to_string()))?,
        );
    }
    let active = renderer.as_mut().expect("renderer initialized");
    let result = operation(active);
    let clear_result = active.clear_current_frame();
    if result.as_ref().err().is_some_and(is_device_loss_error)
        || clear_result
            .as_ref()
            .err()
            .is_some_and(is_device_loss_error)
    {
        // Preserve the expensive process-wide device for ordinary bad-input
        // and conversion errors. Only a terminal device loss causes a rebuild.
        *renderer = None;
    }
    match result {
        Err(error) => Err(ImageError::Renderer(error.to_string())),
        Ok(value) => clear_result
            .map(|()| value)
            .map_err(|error| ImageError::Renderer(error.to_string())),
    }
}

fn decode_first_frame(
    demuxer: &mut Demuxer,
    decoder: &mut Decoder,
    cancelled: &AtomicBool,
    started: Instant,
    policy: ImageDecodePolicy,
) -> Result<crate::ffmpeg::Frame> {
    let mut compressed_bytes = 0_u64;
    for _ in 0..policy.max_packets_before_frame {
        if cancelled.load(Ordering::Acquire) {
            return Err(ImageError::Cancelled);
        }
        if started.elapsed() > policy.decode_timeout {
            return Err(ImageError::WorkLimit(format!(
                "decode exceeded {} seconds",
                policy.decode_timeout.as_secs_f64()
            )));
        }
        match decoder.receive_frame() {
            Ok(DecoderOutputFrame::Frame(frame)) => return Ok(frame),
            Ok(DecoderOutputFrame::EndOfStream) => return Err(ImageError::NoFrame),
            Ok(DecoderOutputFrame::NeedMoreInput) => {}
            Err(error) if error.is_again() => {}
            Err(error) => return Err(ImageError::Decode(error.to_string())),
        }
        match demuxer
            .read_packet()
            .map_err(|error| ImageError::Demux(error.to_string()))?
        {
            Some(packet) => {
                compressed_bytes = compressed_bytes.saturating_add(packet.data().len() as u64);
                if compressed_bytes > policy.max_input_bytes {
                    return Err(ImageError::WorkLimit(format!(
                        "compressed packets exceeded {} bytes",
                        policy.max_input_bytes
                    )));
                }
                match decoder.send_packet(&packet) {
                    Ok(()) => {}
                    Err(error) if error.is_again() => continue,
                    Err(error) => return Err(ImageError::Decode(error.to_string())),
                }
            }
            None => {
                decoder
                    .send_eof()
                    .map_err(|error| ImageError::Decode(error.to_string()))?;
                match decoder.receive_frame() {
                    Ok(DecoderOutputFrame::Frame(frame)) => return Ok(frame),
                    Ok(DecoderOutputFrame::EndOfStream) => return Err(ImageError::NoFrame),
                    Ok(DecoderOutputFrame::NeedMoreInput) => return Err(ImageError::NoFrame),
                    Err(error) if error.is_again() => return Err(ImageError::NoFrame),
                    Err(error) => return Err(ImageError::Decode(error.to_string())),
                }
            }
        }
    }
    Err(ImageError::Decode(format!(
        "no image frame after {} packets",
        policy.max_packets_before_frame
    )))
}

fn ensure_active(
    cancelled: &AtomicBool,
    started: Instant,
    timeout: Duration,
    stage: &str,
) -> Result<()> {
    if cancelled.load(Ordering::Acquire) {
        return Err(ImageError::Cancelled);
    }
    if started.elapsed() > timeout {
        return Err(ImageError::WorkLimit(format!(
            "{stage} exceeded {} seconds",
            timeout.as_secs_f64()
        )));
    }
    Ok(())
}

#[cfg(feature = "wgpu")]
fn is_device_loss_error(error: &crate::PlayerError) -> bool {
    let message = error.to_string().to_ascii_lowercase();
    message.contains("device_lost") || message.contains("device lost")
}

fn validate_pixels(width: u32, height: u32, max_pixels: u64) -> Result<()> {
    let pixels = u64::from(width).saturating_mul(u64::from(height));
    if width == 0 || height == 0 || pixels > max_pixels {
        return Err(ImageError::PixelLimit {
            width,
            height,
            max_pixels,
        });
    }
    Ok(())
}

fn bounded_extent(
    source_width: u32,
    source_height: u32,
    max_width: u32,
    max_height: u32,
) -> (u32, u32) {
    let max_width = if max_width == 0 {
        source_width
    } else {
        max_width
    };
    let max_height = if max_height == 0 {
        source_height
    } else {
        max_height
    };
    if source_width <= max_width && source_height <= max_height {
        return (source_width, source_height);
    }
    let width_limited = u64::from(max_width) * u64::from(source_height)
        <= u64::from(max_height) * u64::from(source_width);
    if width_limited {
        let height = (u64::from(source_height) * u64::from(max_width) / u64::from(source_width))
            .max(1) as u32;
        (max_width.max(1), height)
    } else {
        let width = (u64::from(source_width) * u64::from(max_height) / u64::from(source_height))
            .max(1) as u32;
        (width, max_height.max(1))
    }
}
