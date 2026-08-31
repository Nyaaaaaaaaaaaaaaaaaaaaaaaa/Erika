//! ABI/source compatibility shell for the removed danmaku subsystem.
//!
//! The AV1/AVIF-specialized build deliberately does not parse, lay out, or
//! rasterize danmaku.  The small set of legacy Rust types remains so the
//! unchanged presenter/C ABI can fail predictably instead of breaking linkage.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;

use crate::subtitle::SubtitleFontAttachment;
use crate::text::TextShaper;

const REMOVED: &str = "danmaku support is not included in this AV1/AVIF-specialized Erika build";
const DEFAULT_DANMAKU_TRACK_ID: u64 = 1;
pub const DANMAKU_DEBUG_BUCKETS: usize = 16;

#[derive(Debug, Error)]
pub enum DanmakuError {
    #[error("invalid danmaku field: {0}")]
    InvalidField(String),
    #[error("missing danmaku text")]
    MissingText,
    #[error("danmaku parse error: {0}")]
    Parse(String),
    #[error("danmaku io error: {0}")]
    Io(String),
}

pub type Result<T> = std::result::Result<T, DanmakuError>;

fn removed<T>() -> Result<T> {
    Err(DanmakuError::Parse(REMOVED.to_string()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DanmakuMode {
    Scroll,
    ScrollReverse,
    Top,
    Bottom,
    Special,
}

impl DanmakuMode {
    pub fn from_bilibili_mode(value: u32) -> Self {
        match value {
            6 => Self::ScrollReverse,
            5 => Self::Top,
            4 => Self::Bottom,
            7 => Self::Special,
            _ => Self::Scroll,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DanmakuColor {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
    pub alpha: f32,
}

impl DanmakuColor {
    pub const WHITE: Self = Self::rgb_u8(255, 255, 255);

    pub const fn rgb_u8(red: u8, green: u8, blue: u8) -> Self {
        Self {
            red: red as f32 / 255.0,
            green: green as f32 / 255.0,
            blue: blue as f32 / 255.0,
            alpha: 1.0,
        }
    }

    pub fn rgba(self, opacity: f32) -> [f32; 4] {
        [self.red, self.green, self.blue, self.alpha * opacity]
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuItem {
    pub id: u64,
    pub pts: Duration,
    pub text: String,
    pub mode: DanmakuMode,
    pub font_size: f32,
    pub color: DanmakuColor,
    pub opacity: f32,
    pub is_self: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DanmakuViewport {
    pub width: u32,
    pub height: u32,
    pub scale_factor: f32,
}

impl DanmakuViewport {
    pub fn new(width: u32, height: u32) -> Self {
        Self::with_scale(width, height, 1.0)
    }

    pub fn with_scale(width: u32, height: u32, scale_factor: f32) -> Self {
        Self {
            width: width.max(1),
            height: height.max(1),
            scale_factor: if scale_factor.is_finite() && scale_factor > 0.0 {
                scale_factor
            } else {
                1.0
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuLayoutConfig {
    pub font_size: f32,
    pub opacity: f32,
    pub display_area: f32,
    pub scroll_duration_seconds: f32,
    pub scroll_speed_factor: f32,
    pub track_gap_ratio: f32,
    pub outline_width: f32,
    pub shadow_offset: [f32; 2],
    pub shadow_style: DanmakuShadowStyle,
    pub custom_font_family: String,
    pub custom_font_file_path: String,
    #[doc(hidden)]
    pub custom_font_face_index: u32,
    pub merge_duplicates: bool,
    pub allow_stacking: bool,
    pub allow_scroll_overwrite: bool,
    pub max_quantity: Option<u32>,
    pub max_lines_per_mode: Option<u32>,
    pub block_top: bool,
    pub block_bottom: bool,
    pub block_scroll: bool,
    pub block_words: Vec<String>,
    pub enabled: bool,
}

impl Default for DanmakuLayoutConfig {
    fn default() -> Self {
        Self {
            font_size: 25.0,
            opacity: 1.0,
            display_area: 1.0,
            scroll_duration_seconds: 10.0,
            scroll_speed_factor: 1.0,
            track_gap_ratio: 0.15,
            outline_width: 1.0,
            shadow_offset: [1.0, 1.0],
            shadow_style: DanmakuShadowStyle::Strong,
            custom_font_family: String::new(),
            custom_font_file_path: String::new(),
            custom_font_face_index: 0,
            merge_duplicates: false,
            allow_stacking: false,
            allow_scroll_overwrite: false,
            max_quantity: None,
            max_lines_per_mode: None,
            block_top: false,
            block_bottom: false,
            block_scroll: false,
            block_words: Vec::new(),
            enabled: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DanmakuShadowStyle {
    None,
    Soft,
    Medium,
    #[default]
    Strong,
}

impl DanmakuShadowStyle {
    pub fn from_code(value: i32) -> Self {
        match value {
            0 => Self::None,
            1 => Self::Soft,
            2 => Self::Medium,
            _ => Self::Strong,
        }
    }

    pub fn code(self) -> i32 {
        self as i32
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DanmakuConfigChange {
    Unchanged,
    PaintOnly,
    Layout,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct DanmakuTimeline {
    items: Vec<DanmakuItem>,
}

impl DanmakuTimeline {
    pub fn new(items: Vec<DanmakuItem>) -> Result<Self> {
        if items.is_empty() {
            Ok(Self::default())
        } else {
            removed()
        }
    }
    pub fn from_file(_path: impl AsRef<Path>) -> Result<Self> {
        removed()
    }
    pub fn parse_auto(_input: &str) -> Result<Self> {
        removed()
    }
    pub fn from_json(_input: &str) -> Result<Self> {
        removed()
    }
    pub fn from_json_lines(_input: &str) -> Result<Self> {
        removed()
    }
    pub fn from_bilibili_xml(_input: &str) -> Result<Self> {
        removed()
    }
    pub fn push(&mut self, _item: DanmakuItem) -> Result<()> {
        removed()
    }
    pub fn extend<I>(&mut self, items: I) -> Result<()>
    where
        I: IntoIterator<Item = DanmakuItem>,
    {
        if items.into_iter().next().is_none() {
            Ok(())
        } else {
            removed()
        }
    }
    pub fn items(&self) -> &[DanmakuItem] {
        &self.items
    }
    pub fn window(&self, _start: Duration, _end: Duration) -> Self {
        Self::default()
    }
    pub fn is_empty(&self) -> bool {
        true
    }
    pub fn len(&self) -> usize {
        0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DanmakuTrackSource {
    Unknown,
    File(PathBuf),
    Json,
    Remote(String),
    Manual,
}

impl DanmakuTrackSource {
    pub fn label(&self) -> String {
        match self {
            Self::Unknown => String::new(),
            Self::File(path) => path.to_string_lossy().into_owned(),
            Self::Json => "json".to_string(),
            Self::Remote(value) => value.clone(),
            Self::Manual => "manual".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuTrack {
    id: u64,
    name: String,
    source: DanmakuTrackSource,
}

impl DanmakuTrack {
    pub fn new(
        id: u64,
        name: impl Into<String>,
        source: DanmakuTrackSource,
        _timeline: DanmakuTimeline,
    ) -> Self {
        Self {
            id: id.max(DEFAULT_DANMAKU_TRACK_ID),
            name: name.into(),
            source,
        }
    }
    pub fn id(&self) -> u64 {
        self.id
    }
    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn source(&self) -> &DanmakuTrackSource {
        &self.source
    }
    pub fn timeline(&self) -> &DanmakuTimeline {
        static EMPTY: std::sync::OnceLock<DanmakuTimeline> = std::sync::OnceLock::new();
        EMPTY.get_or_init(DanmakuTimeline::default)
    }
    pub fn enabled(&self) -> bool {
        false
    }
    pub fn offset(&self) -> i64 {
        0
    }
    pub fn offset_duration(&self) -> Duration {
        Duration::ZERO
    }
    pub fn item_count(&self) -> usize {
        0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuTrackInfo {
    pub id: u64,
    pub name: String,
    pub source: String,
    pub enabled: bool,
    pub offset_micros: i64,
    pub item_count: usize,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct DanmakuSession {
    empty: DanmakuTimeline,
}

impl DanmakuSession {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn from_timeline(_timeline: DanmakuTimeline) -> Self {
        Self::default()
    }
    pub fn add_track(
        &mut self,
        _timeline: DanmakuTimeline,
        _name: impl Into<String>,
        _source: DanmakuTrackSource,
    ) -> u64 {
        0
    }
    pub fn add_track_with_offset(
        &mut self,
        _timeline: DanmakuTimeline,
        _name: impl Into<String>,
        _source: DanmakuTrackSource,
        _offset_micros: i64,
    ) -> u64 {
        0
    }
    pub fn replace_default_track(
        &mut self,
        _timeline: DanmakuTimeline,
        _name: impl Into<String>,
        _source: DanmakuTrackSource,
    ) -> u64 {
        0
    }
    pub fn clear(&mut self) {}
    pub fn remove_track(&mut self, _track_id: u64) -> bool {
        false
    }
    pub fn set_track_enabled(&mut self, _track_id: u64, _enabled: bool) -> bool {
        false
    }
    pub fn set_track_offset(&mut self, _track_id: u64, _offset_micros: i64) -> bool {
        false
    }
    pub fn set_global_offset(&mut self, _offset_micros: i64) {}
    pub fn global_offset(&self) -> i64 {
        0
    }
    pub fn tracks(&self) -> &[DanmakuTrack] {
        &[]
    }
    pub fn track_infos(&self) -> Vec<DanmakuTrackInfo> {
        Vec::new()
    }
    pub fn version(&self) -> u64 {
        0
    }
    pub fn active_timeline(&mut self) -> &DanmakuTimeline {
        &self.empty
    }
    pub fn active_timeline_clone(&mut self) -> DanmakuTimeline {
        DanmakuTimeline::default()
    }
    pub fn is_empty(&mut self) -> bool {
        true
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PreparedDanmakuItem {
    pub id: u64,
    pub time: Duration,
    pub text: Arc<str>,
    pub mode: DanmakuMode,
    pub color: DanmakuColor,
    pub opacity: f32,
    pub font_size: f32,
    pub width: f32,
    pub height: f32,
    pub y: f32,
    pub track_index: usize,
    pub scroll_speed: f32,
    pub duration: Duration,
    pub duplicate_count: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DfmPreparedLayout {
    viewport: DanmakuViewport,
}

impl DfmPreparedLayout {
    pub fn items(&self) -> &[PreparedDanmakuItem] {
        &[]
    }
    pub fn stats(&self) -> DanmakuPreparedStats {
        DanmakuPreparedStats::default()
    }
    pub(crate) fn apply_paint_config(&mut self, _config: &DanmakuLayoutConfig) {}
    pub fn frame_layout(&self, media_time: Duration, generation: u64) -> DanmakuFrameLayout {
        DanmakuFrameLayout::empty(media_time, generation, self.viewport)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuFrameLayout {
    pub media_time: Duration,
    pub generation: u64,
    pub viewport: DanmakuViewport,
    pub prepared_stats: DanmakuPreparedStats,
    pub items: Vec<DanmakuPlacedItem>,
}

impl DanmakuFrameLayout {
    pub fn empty(media_time: Duration, generation: u64, viewport: DanmakuViewport) -> Self {
        Self {
            media_time,
            generation,
            viewport,
            prepared_stats: Default::default(),
            items: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuPlacedItem {
    pub item_id: u64,
    pub text: Arc<str>,
    pub mode: DanmakuMode,
    pub track_index: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub font_size: f32,
    pub color: DanmakuColor,
    pub opacity: f32,
    pub outline_width: f32,
    pub shadow_offset: [f32; 2],
    pub shadow_alpha: f32,
    pub duplicate_count: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuRenderPlan {
    pub media_time: Duration,
    pub generation: u64,
    pub viewport: DanmakuViewport,
    pub atlas: Option<Arc<DanmakuGlyphAtlas>>,
    pub items: Vec<DanmakuGlyphInstance>,
    pub frame_stats: DanmakuFrameStats,
}

impl DanmakuRenderPlan {
    pub fn empty(media_time: Duration, generation: u64, viewport: DanmakuViewport) -> Self {
        Self {
            media_time,
            generation,
            viewport,
            atlas: None,
            items: Vec::new(),
            frame_stats: Default::default(),
        }
    }
    pub fn is_empty(&self) -> bool {
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DanmakuFrameStats {
    pub prepared: DanmakuPreparedStats,
    pub placed_items: usize,
    pub scroll_items: usize,
    pub top_items: usize,
    pub bottom_items: usize,
    pub scroll_rows: usize,
    pub scroll_track_min: usize,
    pub scroll_track_max: usize,
    pub scroll_min_y: f32,
    pub scroll_max_y: f32,
    pub scroll_bucket_count: usize,
    pub scroll_buckets: [DanmakuDebugBucket; DANMAKU_DEBUG_BUCKETS],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DanmakuDebugBucket {
    pub key: i32,
    pub count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DanmakuPreparedStats {
    pub source_items: usize,
    pub supported_items: usize,
    pub prepared_items: usize,
    pub filtered_items: usize,
    pub prepared_scroll_items: usize,
    pub prepared_top_items: usize,
    pub prepared_bottom_items: usize,
    pub prepared_scroll_rows: usize,
    pub prepared_scroll_min_y: f32,
    pub prepared_scroll_max_y: f32,
    pub expected_scroll_tracks: usize,
    pub dfm_track_count: usize,
    pub display_area_height: f32,
    pub scroll_area_height: f32,
    pub track_height: f32,
    pub scroll_bucket_count: usize,
    pub scroll_buckets: [DanmakuDebugBucket; DANMAKU_DEBUG_BUCKETS],
}

#[derive(Debug, Clone, PartialEq)]
pub struct DanmakuGlyphInstance {
    pub item_id: u64,
    pub rect: [f32; 4],
    pub tex_rect: [f32; 4],
    pub color_rgba: [f32; 4],
    pub outline_rgba: [f32; 4],
    pub shadow_rgba: [f32; 4],
    pub shadow_offset: [f32; 2],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DanmakuAtlasUpdate {
    pub from_version: u64,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DanmakuGlyphAtlas {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub fill_alpha: Vec<u8>,
    pub outline_alpha: Vec<u8>,
    pub version: u64,
    pub update: Option<DanmakuAtlasUpdate>,
}

impl DanmakuGlyphAtlas {
    pub fn required_len(&self) -> usize {
        self.stride.saturating_mul(self.height as usize)
    }
    pub fn is_valid(&self) -> bool {
        self.width > 0
            && self.stride >= self.width as usize
            && self.fill_alpha.len() >= self.required_len()
            && self.outline_alpha.len() >= self.required_len()
    }
    pub fn incremental_update_from(
        &self,
        version: u64,
        width: u32,
        height: u32,
        stride: usize,
    ) -> Option<&DanmakuAtlasUpdate> {
        self.update.as_ref().filter(|u| {
            u.from_version == version
                && self.width == width
                && self.height == height
                && self.stride == stride
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DanmakuFontSelection {
    pub generation: u64,
    pub fonts: Arc<[SubtitleFontAttachment]>,
}

impl DanmakuFontSelection {
    pub fn new(generation: u64, fonts: impl Into<Arc<[SubtitleFontAttachment]>>) -> Self {
        Self {
            generation,
            fonts: fonts.into(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct DanmakuTextRasterizer;

impl DanmakuTextRasterizer {
    pub fn new(_shaper: TextShaper) -> Self {
        Self
    }
    pub fn for_config(_config: &DanmakuLayoutConfig) -> Self {
        Self
    }
    pub fn for_config_and_selection(
        _config: &DanmakuLayoutConfig,
        _selection: &DanmakuFontSelection,
    ) -> Self {
        Self
    }
    pub fn measure(&self, _text: &str, _font_size: f32) -> TextMeasure {
        TextMeasure {
            width: 0.0,
            height: 0.0,
            ascent: 0.0,
            descent: 0.0,
        }
    }
    pub fn render_plan(&self, layout: &DanmakuFrameLayout) -> DanmakuRenderPlan {
        DanmakuRenderPlan::empty(layout.media_time, layout.generation, layout.viewport)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TextMeasure {
    pub width: f32,
    pub height: f32,
    pub ascent: f32,
    pub descent: f32,
}

#[derive(Debug, Clone)]
pub struct DfmLayoutEngine {
    config: DanmakuLayoutConfig,
}

impl DfmLayoutEngine {
    pub fn new(_timeline: DanmakuTimeline, mut config: DanmakuLayoutConfig) -> Self {
        config.enabled = false;
        Self { config }
    }
    pub fn set_timeline(&mut self, _timeline: DanmakuTimeline) {}
    pub fn sync_timeline(&mut self, _timeline: &DanmakuTimeline) {}
    pub fn clear_timeline(&mut self) {}
    pub fn set_config(&mut self, mut config: DanmakuLayoutConfig) -> bool {
        config.enabled = false;
        let changed = self.config != config;
        self.config = config;
        changed
    }
    pub(crate) fn apply_config(&mut self, mut config: DanmakuLayoutConfig) -> DanmakuConfigChange {
        config.enabled = false;
        if self.config == config {
            DanmakuConfigChange::Unchanged
        } else {
            self.config = config;
            DanmakuConfigChange::Layout
        }
    }
    pub fn set_font_selection(&mut self, _selection: DanmakuFontSelection) -> bool {
        false
    }
    pub fn config(&self) -> &DanmakuLayoutConfig {
        &self.config
    }
    pub(crate) fn rasterizer_clone(&self) -> DanmakuTextRasterizer {
        DanmakuTextRasterizer
    }
    pub(crate) fn set_config_with_rasterizer(
        &mut self,
        config: DanmakuLayoutConfig,
        _rasterizer: DanmakuTextRasterizer,
    ) {
        let _ = self.apply_config(config);
    }
    pub fn prepare(&mut self, viewport: DanmakuViewport, _generation: u64) -> DfmPreparedLayout {
        DfmPreparedLayout { viewport }
    }
    pub fn invalidate_placement_history(&mut self) {}
    pub fn frame_layout(
        &mut self,
        media_time: Duration,
        viewport: DanmakuViewport,
        generation: u64,
    ) -> DanmakuFrameLayout {
        DanmakuFrameLayout::empty(media_time, generation, viewport)
    }
    pub fn render_prepared_plan(
        &self,
        prepared: &DfmPreparedLayout,
        media_time: Duration,
        generation: u64,
    ) -> DanmakuRenderPlan {
        DanmakuRenderPlan::empty(media_time, generation, prepared.viewport)
    }
    pub fn render_plan(
        &mut self,
        media_time: Duration,
        viewport: DanmakuViewport,
        generation: u64,
    ) -> DanmakuRenderPlan {
        DanmakuRenderPlan::empty(media_time, generation, viewport)
    }
}

pub fn parse_bilibili_xml(_input: &str) -> Result<Vec<DanmakuItem>> {
    removed()
}

pub(crate) fn scroll_duration_for_viewport(
    config: &DanmakuLayoutConfig,
    _viewport: DanmakuViewport,
) -> Duration {
    Duration::from_secs_f32(config.scroll_duration_seconds.max(0.0))
}
