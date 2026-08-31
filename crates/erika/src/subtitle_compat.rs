//! Compatibility-only types for the removed subtitle subsystem.
//!
//! Decoding, text parsing, charset conversion and libass rendering are not
//! part of the AV1/AVIF-specialized runtime.  Bitmap primitives stay because
//! the video renderer and debug HUD share those plain data containers.

use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;

const REMOVED: &str = "subtitle support is not included in this AV1/AVIF-specialized Erika build";

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum SubtitleError {
    #[error("invalid subtitle timestamp: {0}")]
    InvalidTimestamp(String),
    #[error("invalid subtitle cue")]
    InvalidCue,
    #[error("invalid subtitle bitmap: width={width} height={height} stride={stride} bytes={bytes}")]
    InvalidBitmap {
        width: u32,
        height: u32,
        stride: usize,
        bytes: usize,
    },
    #[error("subtitle bitmap pointer is null")]
    NullBitmap,
    #[error("subtitle bitmap list exceeded safety limit")]
    BitmapListTooLong,
    #[error("libass error: {0}")]
    Libass(String),
}

pub type Result<T> = std::result::Result<T, SubtitleError>;

fn removed<T>() -> Result<T> {
    Err(SubtitleError::Libass(REMOVED.to_string()))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleFontAttachment {
    pub name: String,
    pub mime_type: Option<String>,
    pub families: Vec<String>,
    pub data: Arc<[u8]>,
}

pub const MAX_MEMORY_SUBTITLE_FONT_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_MEMORY_SUBTITLE_FONT_TOTAL_BYTES: usize = 128 * 1024 * 1024;

impl SubtitleFontAttachment {
    pub fn new(
        name: impl Into<String>,
        mime_type: Option<String>,
        families: Vec<String>,
        data: impl Into<Arc<[u8]>>,
    ) -> Self {
        Self {
            name: name.into(),
            mime_type,
            families,
            data: data.into(),
        }
    }
    pub fn byte_len(&self) -> usize {
        self.data.len()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssTrackResources {
    pub source_stream_index: i64,
    pub codec_private: Arc<[u8]>,
    pub fonts: Arc<[SubtitleFontAttachment]>,
}

impl AssTrackResources {
    pub fn new(
        source_stream_index: i64,
        codec_private: impl Into<Arc<[u8]>>,
        fonts: impl Into<Arc<[SubtitleFontAttachment]>>,
    ) -> Self {
        Self {
            source_stream_index,
            codec_private: codec_private.into(),
            fonts: fonts.into(),
        }
    }
    pub fn font_bytes(&self) -> usize {
        self.fonts
            .iter()
            .map(SubtitleFontAttachment::byte_len)
            .sum()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubtitleTrackSource {
    Embedded { stream_index: i64 },
    External { uri: String },
}

impl SubtitleTrackSource {
    pub const fn embedded(stream_index: i64) -> Self {
        Self::Embedded { stream_index }
    }
    pub fn external(uri: impl Into<String>) -> Self {
        Self::External { uri: uri.into() }
    }
    pub const fn is_embedded(&self) -> bool {
        matches!(self, Self::Embedded { .. })
    }
    pub const fn is_external(&self) -> bool {
        matches!(self, Self::External { .. })
    }
    pub const fn can_remove(&self) -> bool {
        self.is_external()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleTrackConfig {
    pub id: i64,
    pub source: SubtitleTrackSource,
    pub language: Option<String>,
    pub title: Option<String>,
}

impl SubtitleTrackConfig {
    pub fn embedded(id: i64, stream_index: i64) -> Self {
        Self {
            id,
            source: SubtitleTrackSource::embedded(stream_index),
            language: None,
            title: None,
        }
    }
    pub fn external(id: i64, uri: impl Into<String>) -> Self {
        Self {
            id,
            source: SubtitleTrackSource::external(uri),
            language: None,
            title: None,
        }
    }
    pub const fn can_remove(&self) -> bool {
        self.source.can_remove()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleTextFormat {
    PlainText,
    Ass,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleFileFormat {
    Srt,
    WebVtt,
    Ass,
}

impl SubtitleFileFormat {
    pub fn from_path(path: impl AsRef<str>) -> Option<Self> {
        match subtitle_path_extension(path.as_ref())?
            .to_ascii_lowercase()
            .as_str()
        {
            "srt" => Some(Self::Srt),
            "vtt" | "webvtt" => Some(Self::WebVtt),
            "ass" | "ssa" => Some(Self::Ass),
            _ => None,
        }
    }
    pub fn from_uri(uri: impl AsRef<str>) -> Option<Self> {
        Self::from_path(uri_path_component(uri.as_ref()))
    }
}

pub(crate) fn uri_path_component(uri: &str) -> &str {
    let path = uri.split_once('#').map_or(uri, |(path, _)| path);
    path.split_once('?').map_or(path, |(path, _)| path)
}

pub(crate) fn subtitle_path_extension(path: &str) -> Option<&str> {
    path.rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .rsplit_once('.')
        .map(|(_, extension)| extension)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleTextSegment {
    pub format: SubtitleTextFormat,
    pub text: String,
    pub forced: bool,
}

impl SubtitleTextSegment {
    pub fn new(format: SubtitleTextFormat, text: impl Into<String>) -> Self {
        Self {
            format,
            text: text.into(),
            forced: false,
        }
    }
    pub fn with_forced(mut self, forced: bool) -> Self {
        self.forced = forced;
        self
    }
    pub fn display_text(&self) -> String {
        self.text.clone()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedSubtitleFrame {
    pub track_id: i64,
    pub start: Option<Duration>,
    pub end: Option<Duration>,
    pub text: Vec<SubtitleTextSegment>,
    pub bitmap: SubtitleFrame,
    pub forced: bool,
    pub ass_track: Option<Arc<AssTrackResources>>,
}

impl DecodedSubtitleFrame {
    pub fn new(track_id: i64, start: Option<Duration>, end: Option<Duration>) -> Self {
        Self {
            track_id,
            start,
            end,
            text: Vec::new(),
            bitmap: SubtitleFrame {
                pts: start.unwrap_or_default(),
                planes: Vec::new(),
            },
            forced: false,
            ass_track: None,
        }
    }
    pub fn is_empty(&self) -> bool {
        self.text.is_empty() && self.bitmap.planes.is_empty()
    }
    pub fn push_text(&mut self, segment: SubtitleTextSegment) {
        self.forced |= segment.forced;
        if !segment.text.is_empty() {
            self.text.push(segment);
        }
    }
    pub fn push_bitmap_plane(&mut self, plane: SubtitleBitmapPlane, forced: bool) {
        self.forced |= forced;
        self.bitmap.planes.push(plane);
    }
    pub fn with_track_id(mut self, track_id: i64) -> Self {
        self.track_id = track_id;
        self
    }
    pub fn with_ass_track(mut self, resources: Option<Arc<AssTrackResources>>) -> Self {
        self.ass_track = resources;
        self
    }
    pub fn has_ass_chunks(&self) -> bool {
        false
    }
    pub fn has_text(&self) -> bool {
        false
    }
    pub fn text_cues(&self, _fallback_end: Duration) -> Vec<SubtitleCue> {
        Vec::new()
    }
    pub fn to_ass_script(&self, _fallback_end: Duration) -> Option<String> {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleCue {
    pub start: Duration,
    pub end: Duration,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleBitmapPlane {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub canvas_width: u32,
    pub canvas_height: u32,
    pub rgba: Vec<u8>,
}

impl SubtitleBitmapPlane {
    pub fn new(x: i32, y: i32, width: u32, height: u32, rgba: Vec<u8>) -> Self {
        Self {
            x,
            y,
            width,
            height,
            canvas_width: 0,
            canvas_height: 0,
            rgba,
        }
    }
    pub fn with_canvas(mut self, width: u32, height: u32) -> Self {
        self.canvas_width = width;
        self.canvas_height = height;
        self
    }
    pub fn scaled_rect(&self, viewport_width: u32, viewport_height: u32) -> (i32, i32, u32, u32) {
        if self.canvas_width == 0
            || self.canvas_height == 0
            || (self.canvas_width == viewport_width && self.canvas_height == viewport_height)
        {
            return (self.x, self.y, self.width, self.height);
        }
        let sx = viewport_width as f64 / self.canvas_width.max(1) as f64;
        let sy = viewport_height as f64 / self.canvas_height.max(1) as f64;
        let scale = sx.max(sy);
        let ox = (viewport_width as f64 - self.canvas_width as f64 * scale) * 0.5;
        let oy = (viewport_height as f64 - self.canvas_height as f64 * scale) * 0.5;
        (
            (ox + self.x as f64 * scale).round() as i32,
            (oy + self.y as f64 * scale).round() as i32,
            ((self.width as f64 * scale).round() as u32).max(1),
            ((self.height as f64 * scale).round() as u32).max(1),
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubtitleBitmapPlacement {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl SubtitleBitmapPlacement {
    pub const fn new(x: i32, y: i32, width: u32, height: u32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }
    pub fn clipped_to(self, frame_width: u32, frame_height: u32) -> Option<Self> {
        let left = self.x.max(0) as i64;
        let top = self.y.max(0) as i64;
        let right = (self.x as i64 + self.width as i64).min(frame_width as i64);
        let bottom = (self.y as i64 + self.height as i64).min(frame_height as i64);
        (right > left && bottom > top).then(|| {
            Self::new(
                left as i32,
                top as i32,
                (right - left) as u32,
                (bottom - top) as u32,
            )
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SubtitleBitmapColorSpace {
    #[default]
    Srgb,
    Video,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleAlphaBitmap {
    pub placement: SubtitleBitmapPlacement,
    pub stride: usize,
    pub color_rgba: u32,
    pub alpha: Vec<u8>,
}

impl SubtitleAlphaBitmap {
    pub fn new(
        placement: SubtitleBitmapPlacement,
        stride: usize,
        color_rgba: u32,
        alpha: Vec<u8>,
    ) -> Self {
        Self {
            placement,
            stride: stride.max(placement.width as usize),
            color_rgba,
            alpha,
        }
    }
    pub fn required_len(&self) -> usize {
        if self.placement.width == 0 || self.placement.height == 0 {
            0
        } else {
            self.stride
                .saturating_mul(self.placement.height.saturating_sub(1) as usize)
                .saturating_add(self.placement.width as usize)
        }
    }
    pub fn is_valid(&self) -> bool {
        self.alpha.len() >= self.required_len()
    }
    pub fn to_rgba_plane(&self) -> Option<SubtitleBitmapPlane> {
        if !self.is_valid() || self.placement.width == 0 || self.placement.height == 0 {
            return None;
        }
        let color = AssColor::from_libass_rgba(self.color_rgba);
        let width = self.placement.width as usize;
        let height = self.placement.height as usize;
        let mut rgba = vec![0; width * height * 4];
        for y in 0..height {
            for x in 0..width {
                let a = ((u16::from(color.alpha) * u16::from(self.alpha[y * self.stride + x])
                    + 127)
                    / 255) as u8;
                rgba[(y * width + x) * 4..][..4].copy_from_slice(&[
                    color.red,
                    color.green,
                    color.blue,
                    a,
                ]);
            }
        }
        Some(SubtitleBitmapPlane::new(
            self.placement.x,
            self.placement.y,
            self.placement.width,
            self.placement.height,
            rgba,
        ))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleBitmapSet {
    pub pts: Duration,
    pub frame_width: u32,
    pub frame_height: u32,
    pub color_space: SubtitleBitmapColorSpace,
    pub parts: Vec<SubtitleAlphaBitmap>,
    pub changed: bool,
}

impl SubtitleBitmapSet {
    pub fn new(pts: Duration, frame_width: u32, frame_height: u32) -> Self {
        Self {
            pts,
            frame_width,
            frame_height,
            color_space: Default::default(),
            parts: Vec::new(),
            changed: true,
        }
    }
    pub fn with_color_space(mut self, value: SubtitleBitmapColorSpace) -> Self {
        self.color_space = value;
        self
    }
    pub fn with_changed(mut self, value: bool) -> Self {
        self.changed = value;
        self
    }
    pub fn push(&mut self, bitmap: SubtitleAlphaBitmap) {
        if bitmap.placement.width > 0 && bitmap.placement.height > 0 {
            self.parts.push(bitmap);
        }
    }
    pub fn to_frame(&self) -> SubtitleFrame {
        SubtitleFrame {
            pts: self.pts,
            planes: self
                .parts
                .iter()
                .filter_map(SubtitleAlphaBitmap::to_rgba_plane)
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleFrame {
    pub pts: Duration,
    pub planes: Vec<SubtitleBitmapPlane>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubtitleRenderViewport {
    pub width: u32,
    pub height: u32,
    pub storage_width: u32,
    pub storage_height: u32,
}

impl SubtitleRenderViewport {
    pub fn new(width: u32, height: u32) -> Self {
        let width = width.max(1);
        let height = height.max(1);
        Self {
            width,
            height,
            storage_width: width,
            storage_height: height,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubtitleRenderRequest {
    pub pts: Duration,
    pub viewport: SubtitleRenderViewport,
}

impl SubtitleRenderRequest {
    pub fn new(pts: Duration, width: u32, height: u32) -> Self {
        Self {
            pts,
            viewport: SubtitleRenderViewport::new(width, height),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleRenderBackend {
    DebugTimeline,
    Libass,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubtitleRenderOutput {
    Rgba(SubtitleFrame),
    Alpha(SubtitleBitmapSet),
}

impl SubtitleRenderOutput {
    pub fn into_rgba_frame(self) -> SubtitleFrame {
        match self {
            Self::Rgba(v) => v,
            Self::Alpha(v) => v.to_frame(),
        }
    }
}

pub trait SubtitleRenderer {
    fn backend(&self) -> SubtitleRenderBackend;
    fn render(&mut self, request: SubtitleRenderRequest) -> Result<SubtitleRenderOutput>;
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RawAssImage {
    pub w: i32,
    pub h: i32,
    pub stride: i32,
    pub bitmap: *const u8,
    pub color: u32,
    pub dst_x: i32,
    pub dst_y: i32,
    pub next: *const RawAssImage,
    pub image_type: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LibassRenderConfig {
    pub glyph_cache_limit: i32,
    pub bitmap_cache_limit_mb: i32,
}

pub const DEFAULT_SUBTITLE_PRIMARY_COLOR_RGBA: u32 = 0xffff_ffff;
pub const DEFAULT_SUBTITLE_OUTLINE_COLOR_RGBA: u32 = 0x0000_007f;
pub const DEFAULT_SUBTITLE_FONT_SIZE: f64 = 42.0;
pub const DEFAULT_SUBTITLE_OUTLINE_WIDTH: f64 = 2.0;
pub const SUBTITLE_OVERRIDE_FONT_SIZE_FIELDS: u32 = 1 << 2;
pub const SUBTITLE_OVERRIDE_FONT_NAME: u32 = 1 << 3;
pub const SUBTITLE_OVERRIDE_COLORS: u32 = 1 << 4;
pub const SUBTITLE_OVERRIDE_ATTRIBUTES: u32 = 1 << 5;
pub const SUBTITLE_OVERRIDE_BORDER: u32 = 1 << 6;
pub const SUBTITLE_OVERRIDE_ALIGNMENT: u32 = 1 << 7;
pub const SUBTITLE_OVERRIDE_MARGINS: u32 = 1 << 8;
pub const SUBTITLE_OVERRIDE_BLUR: u32 = 1 << 11;
pub const SUBTITLE_OVERRIDE_LEGACY_FORCE: u32 = SUBTITLE_OVERRIDE_FONT_SIZE_FIELDS
    | SUBTITLE_OVERRIDE_FONT_NAME
    | SUBTITLE_OVERRIDE_COLORS
    | SUBTITLE_OVERRIDE_BORDER;
pub const SUBTITLE_OVERRIDE_ALL: u32 = SUBTITLE_OVERRIDE_LEGACY_FORCE
    | SUBTITLE_OVERRIDE_ATTRIBUTES
    | SUBTITLE_OVERRIDE_ALIGNMENT
    | SUBTITLE_OVERRIDE_MARGINS
    | SUBTITLE_OVERRIDE_BLUR;

#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleStyleConfig {
    pub font_family: String,
    pub font_file_path: String,
    pub primary_color_rgba: u32,
    pub outline_color_rgba: u32,
    pub font_size: f64,
    pub outline_width: f64,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike_out: bool,
    pub spacing: f64,
    pub scale_x_percent: f64,
    pub scale_y_percent: f64,
    pub border_style: i32,
    pub shadow_depth: f64,
    pub blur: f64,
    pub alignment: i32,
    pub margin_left: i32,
    pub margin_right: i32,
    pub margin_vertical: i32,
    pub override_mask: u32,
}

impl Default for SubtitleStyleConfig {
    fn default() -> Self {
        Self {
            font_family: String::new(),
            font_file_path: String::new(),
            primary_color_rgba: DEFAULT_SUBTITLE_PRIMARY_COLOR_RGBA,
            outline_color_rgba: DEFAULT_SUBTITLE_OUTLINE_COLOR_RGBA,
            font_size: DEFAULT_SUBTITLE_FONT_SIZE,
            outline_width: DEFAULT_SUBTITLE_OUTLINE_WIDTH,
            bold: false,
            italic: false,
            underline: false,
            strike_out: false,
            spacing: 0.0,
            scale_x_percent: 100.0,
            scale_y_percent: 100.0,
            border_style: 1,
            shadow_depth: 0.0,
            blur: 0.0,
            alignment: 2,
            margin_left: 48,
            margin_right: 48,
            margin_vertical: 54,
            override_mask: 0,
        }
    }
}

impl SubtitleStyleConfig {
    pub fn normalized(mut self) -> Self {
        self.font_family = self.font_family.trim().to_string();
        self.font_file_path = self.font_file_path.trim().to_string();
        self.override_mask &= SUBTITLE_OVERRIDE_ALL;
        self
    }
    pub fn font_family(&self) -> Option<&str> {
        (!self.font_family.trim().is_empty()).then_some(self.font_family.trim())
    }
    pub fn font_file_path(&self) -> Option<&str> {
        (!self.font_file_path.trim().is_empty()).then_some(self.font_file_path.trim())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleAssStyle {
    pub font_scale: f64,
    pub play_res_width: u32,
    pub play_res_height: u32,
    pub style: SubtitleStyleConfig,
    pub memory_fonts: Arc<[SubtitleFontAttachment]>,
    pub memory_font_revision: u64,
}
impl Default for SubtitleAssStyle {
    fn default() -> Self {
        Self {
            font_scale: 1.0,
            play_res_width: 1920,
            play_res_height: 1080,
            style: Default::default(),
            memory_fonts: Arc::from([]),
            memory_font_revision: 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibassRenderOperation {
    SetFrameSize { width: u32, height: u32 },
    SetStorageSize { width: u32, height: u32 },
    SetCacheLimits { glyphs: i32, bitmap_mb: i32 },
    RenderFrame { timestamp_ms: i64 },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibassRenderPlan {
    pub request: SubtitleRenderRequest,
    pub config: LibassRenderConfig,
    pub operations: Vec<LibassRenderOperation>,
}
impl LibassRenderPlan {
    pub fn new(request: SubtitleRenderRequest, config: LibassRenderConfig) -> Self {
        Self {
            request,
            config,
            operations: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct LibassSubtitleRenderer {
    style: SubtitleStyleConfig,
    config: LibassRenderConfig,
}
impl LibassSubtitleRenderer {
    pub fn from_ass_script(_script: impl AsRef<[u8]>, _config: LibassRenderConfig) -> Result<Self> {
        removed()
    }
    pub fn from_ass_script_with_style(
        _script: impl AsRef<[u8]>,
        _config: LibassRenderConfig,
        _style: &SubtitleStyleConfig,
    ) -> Result<Self> {
        removed()
    }
    pub fn from_ass_script_with_style_and_fonts(
        _script: impl AsRef<[u8]>,
        _config: LibassRenderConfig,
        _style: &SubtitleStyleConfig,
        _fonts: Arc<[SubtitleFontAttachment]>,
    ) -> Result<Self> {
        removed()
    }
    pub fn from_ass_track(
        _track_id: i64,
        _resources: &AssTrackResources,
        _config: LibassRenderConfig,
    ) -> Result<Self> {
        removed()
    }
    pub fn from_ass_track_with_style(
        _track_id: i64,
        _resources: &AssTrackResources,
        _config: LibassRenderConfig,
        _style: &SubtitleStyleConfig,
    ) -> Result<Self> {
        removed()
    }
    pub fn from_ass_track_with_style_and_fonts(
        _track_id: i64,
        _resources: &AssTrackResources,
        _config: LibassRenderConfig,
        _style: &SubtitleStyleConfig,
        _fonts: Arc<[SubtitleFontAttachment]>,
    ) -> Result<Self> {
        removed()
    }
    pub fn process_chunk(
        &mut self,
        _chunk: &str,
        _start: Duration,
        _end: Option<Duration>,
    ) -> Result<()> {
        removed()
    }
    pub fn flush_events(&mut self) {}
    pub fn set_font_scale(&mut self, _scale: f64) {}
    pub fn set_override_font_scale(&mut self, _scale: f64) {}
    pub fn set_play_res_height(&mut self, _height: u32) {}
    pub fn set_style(&mut self, style: &SubtitleStyleConfig) {
        self.style = style.clone()
    }
    pub fn style(&self) -> &SubtitleStyleConfig {
        &self.style
    }
    pub fn config(&self) -> LibassRenderConfig {
        self.config
    }
    pub fn render_plan(&self, request: SubtitleRenderRequest) -> LibassRenderPlan {
        LibassRenderPlan::new(request, self.config)
    }
}
impl SubtitleRenderer for LibassSubtitleRenderer {
    fn backend(&self) -> SubtitleRenderBackend {
        SubtitleRenderBackend::Libass
    }
    fn render(&mut self, _request: SubtitleRenderRequest) -> Result<SubtitleRenderOutput> {
        removed()
    }
}

pub struct LibassImageImporter;
impl LibassImageImporter {
    pub unsafe fn import_raw_list(
        _pts: Duration,
        _frame_width: u32,
        _frame_height: u32,
        _first: *const RawAssImage,
        _changed: bool,
    ) -> Result<SubtitleBitmapSet> {
        removed()
    }
}

pub type SubtitleViewport = SubtitleRenderViewport;
pub type SubtitleRendererBackend = SubtitleRenderBackend;

impl SubtitleFrame {
    pub fn from_ass_bitmaps<'a>(
        pts: Duration,
        bitmaps: impl IntoIterator<Item = &'a AssBitmapPlane>,
    ) -> Result<Self> {
        let mut set = SubtitleBitmapSet::new(pts, 1, 1);
        for bitmap in bitmaps {
            if let Some(part) = bitmap.as_alpha_bitmap()? {
                set.push(part);
            }
        }
        Ok(set.to_frame())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleFrameChange {
    Changed,
    Unchanged,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleRenderResult {
    pub backend: SubtitleRendererBackend,
    pub change: SubtitleFrameChange,
    pub frame: SubtitleFrame,
}

#[derive(Debug, Clone, Default)]
pub struct SubtitleRendererCore {
    timeline: SubtitleTimeline,
}
impl SubtitleRendererCore {
    pub fn new_debug(_timeline: SubtitleTimeline) -> Self {
        Self::default()
    }
    pub fn timeline(&self) -> &SubtitleTimeline {
        &self.timeline
    }
    pub fn render(&mut self, pts: Duration, _viewport: SubtitleViewport) -> SubtitleRenderResult {
        SubtitleRenderResult {
            backend: SubtitleRenderBackend::DebugTimeline,
            change: SubtitleFrameChange::Unchanged,
            frame: SubtitleFrame {
                pts,
                planes: Vec::new(),
            },
        }
    }
    pub fn render_ass_bitmaps<'a>(
        pts: Duration,
        _bitmaps: impl IntoIterator<Item = &'a AssBitmapPlane>,
    ) -> Result<SubtitleRenderResult> {
        Ok(SubtitleRenderResult {
            backend: SubtitleRenderBackend::Libass,
            change: SubtitleFrameChange::Unchanged,
            frame: SubtitleFrame {
                pts,
                planes: Vec::new(),
            },
        })
    }
}
impl SubtitleRenderer for SubtitleRendererCore {
    fn backend(&self) -> SubtitleRenderBackend {
        SubtitleRenderBackend::DebugTimeline
    }
    fn render(&mut self, request: SubtitleRenderRequest) -> Result<SubtitleRenderOutput> {
        Ok(SubtitleRenderOutput::Rgba(
            self.render(request.pts, request.viewport).frame,
        ))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AssColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}
impl AssColor {
    pub fn from_libass_rgba(color: u32) -> Self {
        Self {
            red: (color >> 24) as u8,
            green: (color >> 16) as u8,
            blue: (color >> 8) as u8,
            alpha: 0xff - (color as u8),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssBitmapPlane {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub color: u32,
    pub alpha: Vec<u8>,
}
impl AssBitmapPlane {
    pub fn new(
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        stride: usize,
        color: u32,
        alpha: Vec<u8>,
    ) -> Result<Self> {
        let required = stride.saturating_mul(height as usize);
        if stride < width as usize || alpha.len() < required {
            return Err(SubtitleError::InvalidBitmap {
                width,
                height,
                stride,
                bytes: alpha.len(),
            });
        }
        Ok(Self {
            x,
            y,
            width,
            height,
            stride,
            color,
            alpha,
        })
    }
    pub fn to_rgba_plane(&self) -> Result<SubtitleBitmapPlane> {
        self.as_alpha_bitmap()?
            .and_then(|b| b.to_rgba_plane())
            .ok_or(SubtitleError::InvalidBitmap {
                width: self.width,
                height: self.height,
                stride: self.stride,
                bytes: self.alpha.len(),
            })
    }
    pub fn as_alpha_bitmap(&self) -> Result<Option<SubtitleAlphaBitmap>> {
        if self.width == 0 || self.height == 0 {
            return Ok(None);
        }
        Ok(Some(SubtitleAlphaBitmap::new(
            SubtitleBitmapPlacement::new(self.x, self.y, self.width, self.height),
            self.stride,
            self.color,
            self.alpha.clone(),
        )))
    }
}

#[derive(Debug, Clone, Default)]
pub struct SubtitleTimeline {
    cues: Vec<SubtitleCue>,
}
impl SubtitleTimeline {
    pub fn new(_cues: Vec<SubtitleCue>) -> Self {
        Self::default()
    }
    pub fn cues(&self) -> &[SubtitleCue] {
        &self.cues
    }
    pub fn active_cues(&self, _pts: Duration) -> Vec<&SubtitleCue> {
        Vec::new()
    }
    pub fn render_debug_frame(&self, pts: Duration, _width: u32, _height: u32) -> SubtitleFrame {
        SubtitleFrame {
            pts,
            planes: Vec::new(),
        }
    }
}

pub fn parse_srt(_input: &str) -> Result<SubtitleTimeline> {
    removed()
}
pub fn parse_webvtt(_input: &str) -> Result<SubtitleTimeline> {
    removed()
}
pub fn parse_ass_events(_input: &str) -> Result<SubtitleTimeline> {
    removed()
}
pub fn parse_subtitle_text_file(
    _format: SubtitleFileFormat,
    _input: &str,
) -> Result<SubtitleTimeline> {
    removed()
}
pub fn decoded_subtitle_frames_to_timeline<'a>(
    _frames: impl IntoIterator<Item = &'a DecodedSubtitleFrame>,
    _fallback_end: Duration,
) -> SubtitleTimeline {
    SubtitleTimeline::default()
}
pub fn decoded_subtitle_frames_to_ass_script<'a>(
    _frames: impl IntoIterator<Item = &'a DecodedSubtitleFrame>,
    _fallback_end: Duration,
) -> Option<String> {
    None
}
pub fn decoded_subtitle_frames_to_ass_script_with_style<'a>(
    _frames: impl IntoIterator<Item = &'a DecodedSubtitleFrame>,
    _fallback_end: Duration,
    _style: &SubtitleAssStyle,
) -> Option<String> {
    None
}
