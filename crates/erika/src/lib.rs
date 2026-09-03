#[cfg(target_os = "android")]
pub mod android;
pub mod apple;
pub mod audio;
pub mod core;
#[path = "danmaku_compat.rs"]
pub mod danmaku;
pub mod debug_hud;
pub mod ffmpeg;
pub mod image;
#[cfg(target_env = "ohos")]
pub mod ohos;
#[cfg(any(target_env = "ohos", test))]
mod ohos_av1;
pub mod overlay;
pub mod playback;
pub mod presenter;
pub mod renderer;
pub mod source;
#[path = "subtitle_compat.rs"]
pub mod subtitle;
#[path = "subtitle_charset_compat.rs"]
pub mod subtitle_charset;
pub mod text;
#[cfg(target_os = "windows")]
pub mod windows;

mod trace;

// Subtitle and danmaku rendering were removed from the AV1/AVIF-specialized
// runtime. Keep the internal symbol temporarily so the compatibility-only
// The optional debug HUD keeps a compact ASCII font; subtitle and danmaku
// rendering cannot use it.
pub(crate) const NIPAPLAY_FALLBACK_FONT: &[u8] = include_bytes!("../assets/hudfont.ttf");

pub use core::*;
