use crate::ohos_av1::av1_codec_config_obus;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OhosVideoCodec {
    Av1,
    Avc,
    Hevc,
    Mpeg2,
    Mpeg4,
    H263,
    Vp8,
    Vp9,
}

impl OhosVideoCodec {
    pub(super) fn mime(self) -> &'static [u8] {
        match self {
            Self::Av1 => b"video/av1\0",
            Self::Avc => b"video/avc\0",
            Self::Hevc => b"video/hevc\0",
            Self::Mpeg2 => b"video/mpeg2\0",
            Self::Mpeg4 => b"video/mp4v-es\0",
            Self::H263 => b"video/h263\0",
            Self::Vp8 => b"video/x-vnd.on2.vp8\0",
            Self::Vp9 => b"video/x-vnd.on2.vp9\0",
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Av1 => "av1",
            Self::Avc => "h264",
            Self::Hevc => "hevc",
            Self::Mpeg2 => "mpeg2video",
            Self::Mpeg4 => "mpeg4",
            Self::H263 => "h263",
            Self::Vp8 => "vp8",
            Self::Vp9 => "vp9",
        }
    }
}

pub(super) fn normalize_codec_config(
    codec: OhosVideoCodec,
    codec_config: &[u8],
) -> Result<(Vec<u8>, Option<usize>, Vec<u8>), String> {
    if codec_config.is_empty() {
        return Ok((Vec::new(), None, Vec::new()));
    }
    if codec == OhosVideoCodec::Av1 {
        let config_obus = av1_codec_config_obus(codec_config).map_err(|error| error.to_string())?;
        return Ok((config_obus.to_vec(), None, Vec::new()));
    }
    if matches!(codec, OhosVideoCodec::Mpeg2 | OhosVideoCodec::Mpeg4) {
        // MPEG sequence headers are already elementary stream bytes. Feed them
        // again with the first keyframe after start/flush, like AVC/HEVC headers.
        return Ok((codec_config.to_vec(), None, codec_config.to_vec()));
    }
    if matches!(
        codec,
        OhosVideoCodec::H263 | OhosVideoCodec::Vp8 | OhosVideoCodec::Vp9
    ) {
        return Ok((codec_config.to_vec(), None, Vec::new()));
    }
    if is_annex_b(codec_config) {
        return Ok((codec_config.to_vec(), None, codec_config.to_vec()));
    }
    let (parameter_sets, nal_length_size) = match codec {
        OhosVideoCodec::Avc => avcc_to_annex_b(codec_config),
        OhosVideoCodec::Hevc => hvcc_to_annex_b(codec_config),
        _ => unreachable!("non-NAL codec configs are normalized above"),
    }?;
    Ok((codec_config.to_vec(), nal_length_size, parameter_sets))
}

fn avcc_to_annex_b(config: &[u8]) -> Result<(Vec<u8>, Option<usize>), String> {
    if config.len() < 7 || config[0] != 1 {
        return Err("invalid AVCDecoderConfigurationRecord".to_string());
    }
    let nal_length_size = (config[4] & 0x03) as usize + 1;
    let mut cursor = 6;
    let mut output = Vec::with_capacity(config.len() + 16);
    let sequence_parameter_sets = (config[5] & 0x1f) as usize;
    for _ in 0..sequence_parameter_sets {
        append_config_nal(config, &mut cursor, &mut output)?;
    }
    let picture_parameter_sets = *config
        .get(cursor)
        .ok_or_else(|| "AVC configuration is missing PPS count".to_string())?
        as usize;
    cursor += 1;
    for _ in 0..picture_parameter_sets {
        append_config_nal(config, &mut cursor, &mut output)?;
    }
    if output.is_empty() {
        return Err("AVC configuration contains no SPS/PPS data".to_string());
    }
    Ok((output, Some(nal_length_size)))
}

fn hvcc_to_annex_b(config: &[u8]) -> Result<(Vec<u8>, Option<usize>), String> {
    if config.len() < 23 || config[0] != 1 {
        return Err("invalid HEVCDecoderConfigurationRecord".to_string());
    }
    let nal_length_size = (config[21] & 0x03) as usize + 1;
    let array_count = config[22] as usize;
    let mut cursor = 23usize;
    let mut output = Vec::with_capacity(config.len() + array_count * 4);
    for _ in 0..array_count {
        cursor = cursor
            .checked_add(1)
            .filter(|cursor| *cursor + 2 <= config.len())
            .ok_or_else(|| "truncated HEVC configuration array".to_string())?;
        let nal_count = u16::from_be_bytes([config[cursor], config[cursor + 1]]) as usize;
        cursor += 2;
        for _ in 0..nal_count {
            append_config_nal(config, &mut cursor, &mut output)?;
        }
    }
    if output.is_empty() {
        return Err("HEVC configuration contains no VPS/SPS/PPS data".to_string());
    }
    Ok((output, Some(nal_length_size)))
}

fn append_config_nal(
    config: &[u8],
    cursor: &mut usize,
    output: &mut Vec<u8>,
) -> Result<(), String> {
    if *cursor + 2 > config.len() {
        return Err("truncated codec configuration NAL length".to_string());
    }
    let nal_size = u16::from_be_bytes([config[*cursor], config[*cursor + 1]]) as usize;
    *cursor += 2;
    let end = cursor
        .checked_add(nal_size)
        .filter(|end| *end <= config.len())
        .ok_or_else(|| "truncated codec configuration NAL data".to_string())?;
    output.extend_from_slice(&[0, 0, 0, 1]);
    output.extend_from_slice(&config[*cursor..end]);
    *cursor = end;
    Ok(())
}

pub(super) fn length_prefixed_packet_to_annex_b(
    packet: &[u8],
    nal_length_size: usize,
) -> Result<Vec<u8>, String> {
    if !(1..=4).contains(&nal_length_size) {
        return Err(format!("invalid NAL length size {nal_length_size}"));
    }
    let mut cursor = 0usize;
    let mut output = Vec::with_capacity(packet.len().saturating_add(16));
    while cursor < packet.len() {
        if cursor + nal_length_size > packet.len() {
            return Err("truncated length-prefixed video packet".to_string());
        }
        let mut nal_size = 0usize;
        for byte in &packet[cursor..cursor + nal_length_size] {
            nal_size = nal_size
                .checked_shl(8)
                .and_then(|value| value.checked_add(*byte as usize))
                .ok_or_else(|| "video packet NAL size overflowed".to_string())?;
        }
        cursor += nal_length_size;
        if nal_size == 0 {
            continue;
        }
        let end = cursor
            .checked_add(nal_size)
            .filter(|end| *end <= packet.len())
            .ok_or_else(|| {
                format!(
                    "video packet NAL size {nal_size} exceeds remaining {} bytes",
                    packet.len().saturating_sub(cursor)
                )
            })?;
        output.extend_from_slice(&[0, 0, 0, 1]);
        output.extend_from_slice(&packet[cursor..end]);
        cursor = end;
    }
    if output.is_empty() && !packet.is_empty() {
        return Err("length-prefixed video packet contains no NAL data".to_string());
    }
    Ok(output)
}

fn is_annex_b(data: &[u8]) -> bool {
    data.starts_with(&[0, 0, 1]) || data.starts_with(&[0, 0, 0, 1])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn avc_and_hevc_configs_prepare_parameter_sets_and_packet_lengths() {
        let avcc = [
            1, 100, 0, 31, 0xff, 0xe1, 0, 3, 0x67, 0x64, 0, 1, 0, 2, 0x68, 0,
        ];
        let (config, length_size, headers) =
            normalize_codec_config(OhosVideoCodec::Avc, &avcc).unwrap();
        assert_eq!(config, avcc);
        assert_eq!(length_size, Some(4));
        assert_eq!(headers, [0, 0, 0, 1, 0x67, 0x64, 0, 0, 0, 0, 1, 0x68, 0]);

        let mut hvcc = vec![0; 23];
        hvcc[0] = 1;
        hvcc[21] = 0xfd;
        hvcc[22] = 1;
        hvcc.extend_from_slice(&[0xa0, 0, 1, 0, 3, 0x40, 1, 0x0c]);
        let (config, length_size, headers) =
            normalize_codec_config(OhosVideoCodec::Hevc, &hvcc).unwrap();
        assert_eq!(config, hvcc);
        assert_eq!(length_size, Some(2));
        assert_eq!(headers, [0, 0, 0, 1, 0x40, 1, 0x0c]);
    }

    #[test]
    fn all_packet_length_sizes_become_annex_b() {
        for length_size in 1..=4 {
            let mut packet = vec![0; length_size];
            packet[length_size - 1] = 2;
            packet.extend_from_slice(&[0x65, 0x88]);
            packet.extend_from_slice(&vec![0; length_size]);
            *packet.last_mut().unwrap() = 1;
            packet.push(0x06);
            assert_eq!(
                length_prefixed_packet_to_annex_b(&packet, length_size).unwrap(),
                [0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x06]
            );
        }
    }

    #[test]
    fn elementary_headers_survive_decoder_start_and_flush_preparation() {
        let config = [0, 0, 1, 0xb0, 1, 0, 0, 1, 0x20, 0x80];
        for codec in [
            OhosVideoCodec::Mpeg2,
            OhosVideoCodec::Mpeg4,
            OhosVideoCodec::Avc,
            OhosVideoCodec::Hevc,
        ] {
            assert_eq!(
                normalize_codec_config(codec, &config).unwrap(),
                (config.to_vec(), None, config.to_vec())
            );
        }
    }

    #[test]
    fn non_nal_codecs_do_not_treat_config_as_avcc_or_hvcc() {
        let config = [1, 2, 3, 4];
        for codec in [
            OhosVideoCodec::H263,
            OhosVideoCodec::Vp8,
            OhosVideoCodec::Vp9,
        ] {
            assert_eq!(
                normalize_codec_config(codec, &config).unwrap(),
                (config.to_vec(), None, Vec::new())
            );
        }
        let av1c = [0x81, 0, 0, 0, 0x0a, 2, 0x12, 0x34];
        assert_eq!(
            normalize_codec_config(OhosVideoCodec::Av1, &av1c).unwrap(),
            (av1c[4..].to_vec(), None, Vec::new())
        );
    }

    #[test]
    fn truncated_config_and_packet_data_are_rejected() {
        for codec in [OhosVideoCodec::Avc, OhosVideoCodec::Hevc] {
            assert!(normalize_codec_config(codec, &[1, 2]).is_err());
        }
        let truncated_sps = [1, 100, 0, 31, 0xff, 0xe1, 0, 3, 0x67];
        assert!(normalize_codec_config(OhosVideoCodec::Avc, &truncated_sps).is_err());
        assert!(length_prefixed_packet_to_annex_b(&[0, 0, 0], 4).is_err());
        assert!(length_prefixed_packet_to_annex_b(&[0, 0, 0, 3, 0x65], 4).is_err());
        assert!(length_prefixed_packet_to_annex_b(&[0, 0, 0, 0], 4).is_err());
    }
}
