//! Compatibility shell for the removed external-subtitle charset pipeline.

use crate::source::{ByteRange, MediaSource, Result};

pub struct CharsetInspection {
    pub detected: &'static str,
    pub utf8: Option<Vec<u8>>,
}

pub fn detect_and_transcode(_bytes: &[u8]) -> Option<Vec<u8>> {
    None
}

pub fn inspect(_bytes: &[u8]) -> CharsetInspection {
    CharsetInspection {
        detected: "unsupported",
        utf8: None,
    }
}

#[derive(Debug)]
pub struct TranscodedMemorySource {
    uri: String,
    bytes: Vec<u8>,
}

impl TranscodedMemorySource {
    pub fn new(uri: impl Into<String>, bytes: Vec<u8>) -> Self {
        Self {
            uri: uri.into(),
            bytes,
        }
    }
}

impl MediaSource for TranscodedMemorySource {
    fn uri(&self) -> &str {
        &self.uri
    }
    fn len(&mut self) -> Result<Option<u64>> {
        Ok(Some(self.bytes.len() as u64))
    }
    fn read_range(&mut self, range: ByteRange) -> Result<Vec<u8>> {
        let start = usize::try_from(range.start).unwrap_or(usize::MAX);
        if start >= self.bytes.len() {
            return Ok(Vec::new());
        }
        let end = range.length.map_or(self.bytes.len(), |len| {
            start
                .saturating_add(usize::try_from(len).unwrap_or(usize::MAX))
                .min(self.bytes.len())
        });
        Ok(self.bytes[start..end].to_vec())
    }
}
