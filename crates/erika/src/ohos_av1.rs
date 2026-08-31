use std::fmt;

const AV1_CODEC_CONFIGURATION_RECORD_MARKER: u8 = 0x80;
const AV1_CODEC_CONFIGURATION_RECORD_VERSION_MASK: u8 = 0x7f;
const AV1_CODEC_CONFIGURATION_RECORD_VERSION: u8 = 1;
const AV1_CODEC_CONFIGURATION_RECORD_HEADER_LEN: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Av1CodecConfigError {
    TruncatedConfigurationRecord,
    UnsupportedConfigurationRecordVersion(u8),
}

impl fmt::Display for Av1CodecConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TruncatedConfigurationRecord => {
                formatter.write_str("truncated AV1CodecConfigurationRecord")
            }
            Self::UnsupportedConfigurationRecordVersion(version) => write!(
                formatter,
                "unsupported AV1CodecConfigurationRecord version {version}"
            ),
        }
    }
}

pub(crate) fn av1_codec_config_obus(config: &[u8]) -> Result<&[u8], Av1CodecConfigError> {
    let Some(first) = config.first().copied() else {
        return Ok(config);
    };
    if first & AV1_CODEC_CONFIGURATION_RECORD_MARKER == 0 {
        return Ok(config);
    }
    if config.len() < AV1_CODEC_CONFIGURATION_RECORD_HEADER_LEN {
        return Err(Av1CodecConfigError::TruncatedConfigurationRecord);
    }
    let version = first & AV1_CODEC_CONFIGURATION_RECORD_VERSION_MASK;
    if version != AV1_CODEC_CONFIGURATION_RECORD_VERSION {
        return Err(Av1CodecConfigError::UnsupportedConfigurationRecordVersion(
            version,
        ));
    }
    Ok(&config[AV1_CODEC_CONFIGURATION_RECORD_HEADER_LEN..])
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HardwareAv1CapabilityRejection {
    Unavailable,
    EmptyCodecName,
    UnsupportedVideoSize,
}

pub(crate) fn select_hardware_av1_codec_name(
    codec_name: Option<&str>,
    video_size_supported: bool,
) -> Result<&str, HardwareAv1CapabilityRejection> {
    let codec_name = codec_name.ok_or(HardwareAv1CapabilityRejection::Unavailable)?;
    if codec_name.is_empty() {
        return Err(HardwareAv1CapabilityRejection::EmptyCodecName);
    }
    if !video_size_supported {
        return Err(HardwareAv1CapabilityRejection::UnsupportedVideoSize);
    }
    Ok(codec_name)
}

#[cfg(test)]
mod tests {
    use super::{
        Av1CodecConfigError, HardwareAv1CapabilityRejection, av1_codec_config_obus,
        select_hardware_av1_codec_name,
    };

    #[test]
    fn av1c_exposes_only_configuration_obus() {
        let av1c = [0x81, 0x08, 0x0c, 0x00, 0x0a, 0x02, 0x12, 0x34];
        assert_eq!(av1_codec_config_obus(&av1c), Ok(&av1c[4..]));
    }

    #[test]
    fn av1c_without_configuration_obus_is_valid() {
        let av1c = [0x81, 0x08, 0x0c, 0x00];
        assert_eq!(av1_codec_config_obus(&av1c), Ok(&[][..]));
    }

    #[test]
    fn raw_obus_are_preserved() {
        let obus = [0x0a, 0x02, 0x12, 0x34];
        assert_eq!(av1_codec_config_obus(&obus), Ok(&obus[..]));
        let annex_b_shaped_obus = [0x00, 0x00, 0x01, 0x12];
        assert_eq!(
            av1_codec_config_obus(&annex_b_shaped_obus),
            Ok(&annex_b_shaped_obus[..])
        );
        assert_eq!(av1_codec_config_obus(&[]), Ok(&[][..]));
    }

    #[test]
    fn malformed_av1c_is_rejected() {
        assert_eq!(
            av1_codec_config_obus(&[0x81, 0x08]),
            Err(Av1CodecConfigError::TruncatedConfigurationRecord)
        );
        assert_eq!(
            av1_codec_config_obus(&[0x82, 0x08, 0x0c, 0x00]),
            Err(Av1CodecConfigError::UnsupportedConfigurationRecordVersion(
                2
            ))
        );
    }

    #[test]
    fn hardware_capability_requires_a_named_size_compatible_decoder() {
        assert_eq!(
            select_hardware_av1_codec_name(Some("codec.av1.hw"), true),
            Ok("codec.av1.hw")
        );
        assert_eq!(
            select_hardware_av1_codec_name(None, true),
            Err(HardwareAv1CapabilityRejection::Unavailable)
        );
        assert_eq!(
            select_hardware_av1_codec_name(Some(""), true),
            Err(HardwareAv1CapabilityRejection::EmptyCodecName)
        );
        assert_eq!(
            select_hardware_av1_codec_name(Some("codec.av1.hw"), false),
            Err(HardwareAv1CapabilityRejection::UnsupportedVideoSize)
        );
    }
}
