//! PTP/IP (ISO 15740 transport binding) packets and the stream framer.

use thiserror::Error;
use uuid::Uuid;

use crate::ptp::{ByteBuffer, EventCode, OperationCode, ReadError, ResponseCode};

/// PTP/IP packet types. Every packet starts with a u32 total length (header
/// included) and a u32 packet type.
///
/// Standard TCP port is 15740. Both the command and the event connection
/// carry this header; data phases ride on the command connection as
/// StartData / Data / EndData keyed by transaction ID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum PtpIpPacketType {
    InitCommandRequest = 1,
    InitCommandAck = 2,
    InitEventRequest = 3,
    InitEventAck = 4,
    InitFail = 5,
    CmdRequest = 6,
    CmdResponse = 7,
    Event = 8,
    StartData = 9,
    Data = 10,
    CancelTransaction = 11,
    EndData = 12,
    ProbeRequest = 13,
    ProbeResponse = 14,
}

impl PtpIpPacketType {
    pub fn from_raw(v: u32) -> Option<Self> {
        use PtpIpPacketType::*;
        Some(match v {
            1 => InitCommandRequest,
            2 => InitCommandAck,
            3 => InitEventRequest,
            4 => InitEventAck,
            5 => InitFail,
            6 => CmdRequest,
            7 => CmdResponse,
            8 => Event,
            9 => StartData,
            10 => Data,
            11 => CancelTransaction,
            12 => EndData,
            13 => ProbeRequest,
            14 => ProbeResponse,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PtpIpPacket {
    InitCommandRequest {
        guid: Vec<u8>,
        name: String,
        protocol_version: u32,
    },
    InitCommandAck {
        connection_number: u32,
        guid: Vec<u8>,
        name: String,
        protocol_version: u32,
    },
    InitEventRequest {
        connection_number: u32,
    },
    InitEventAck,
    InitFail {
        reason: u32,
    },
    CmdRequest {
        data_phase: u32,
        code: OperationCode,
        transaction_id: u32,
        parameters: Vec<u32>,
    },
    CmdResponse {
        code: ResponseCode,
        transaction_id: u32,
        parameters: Vec<u32>,
    },
    Event {
        code: EventCode,
        transaction_id: u32,
        parameters: Vec<u32>,
    },
    StartData {
        transaction_id: u32,
        total_length: u64,
    },
    Data {
        transaction_id: u32,
        payload: Vec<u8>,
    },
    CancelTransaction {
        transaction_id: u32,
    },
    EndData {
        transaction_id: u32,
        payload: Vec<u8>,
    },
    ProbeRequest,
    ProbeResponse,
}

/// Data-phase direction flags carried in CmdRequest.
pub mod data_phase {
    pub const NO_DATA_OR_DATA_IN: u32 = 1;
    pub const DATA_OUT: u32 = 2;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum DecodeError {
    #[error("need {0} more bytes")]
    NeedMoreBytes(usize),
    #[error("bad packet length {0}")]
    BadLength(u32),
    #[error("unknown packet type {0}")]
    UnknownType(u32),
    #[error("truncated packet")]
    Truncated,
}

impl From<ReadError> for DecodeError {
    fn from(_: ReadError) -> Self {
        DecodeError::Truncated
    }
}

impl PtpIpPacket {
    pub const HEADER_LENGTH: usize = 8;
    pub const STANDARD_PORT: u16 = 15740;
    pub const PROTOCOL_VERSION: u32 = 0x0001_0000;

    pub fn packet_type(&self) -> PtpIpPacketType {
        use PtpIpPacketType as T;
        match self {
            Self::InitCommandRequest { .. } => T::InitCommandRequest,
            Self::InitCommandAck { .. } => T::InitCommandAck,
            Self::InitEventRequest { .. } => T::InitEventRequest,
            Self::InitEventAck => T::InitEventAck,
            Self::InitFail { .. } => T::InitFail,
            Self::CmdRequest { .. } => T::CmdRequest,
            Self::CmdResponse { .. } => T::CmdResponse,
            Self::Event { .. } => T::Event,
            Self::StartData { .. } => T::StartData,
            Self::Data { .. } => T::Data,
            Self::CancelTransaction { .. } => T::CancelTransaction,
            Self::EndData { .. } => T::EndData,
            Self::ProbeRequest => T::ProbeRequest,
            Self::ProbeResponse => T::ProbeResponse,
        }
    }

    // MARK: Encoding

    pub fn encode(&self) -> Vec<u8> {
        let mut body = ByteBuffer::new();
        match self {
            Self::InitCommandRequest {
                guid,
                name,
                protocol_version,
            } => {
                body.write_bytes(&pad16(guid));
                body.write_utf16le_z(name);
                body.write_u32(*protocol_version);
            }
            Self::InitCommandAck {
                connection_number,
                guid,
                name,
                protocol_version,
            } => {
                body.write_u32(*connection_number);
                body.write_bytes(&pad16(guid));
                body.write_utf16le_z(name);
                body.write_u32(*protocol_version);
            }
            Self::InitEventRequest { connection_number } => body.write_u32(*connection_number),
            Self::InitEventAck | Self::ProbeRequest | Self::ProbeResponse => {}
            Self::InitFail { reason } => body.write_u32(*reason),
            Self::CmdRequest {
                data_phase,
                code,
                transaction_id,
                parameters,
            } => {
                body.write_u32(*data_phase);
                body.write_u16(code.0);
                body.write_u32(*transaction_id);
                parameters.iter().for_each(|p| body.write_u32(*p));
            }
            Self::CmdResponse {
                code,
                transaction_id,
                parameters,
            } => {
                body.write_u16(code.0);
                body.write_u32(*transaction_id);
                parameters.iter().for_each(|p| body.write_u32(*p));
            }
            Self::Event {
                code,
                transaction_id,
                parameters,
            } => {
                body.write_u16(code.0);
                body.write_u32(*transaction_id);
                parameters.iter().for_each(|p| body.write_u32(*p));
            }
            Self::StartData {
                transaction_id,
                total_length,
            } => {
                body.write_u32(*transaction_id);
                body.write_u64(*total_length);
            }
            Self::Data {
                transaction_id,
                payload,
            }
            | Self::EndData {
                transaction_id,
                payload,
            } => {
                body.write_u32(*transaction_id);
                body.write_bytes(payload);
            }
            Self::CancelTransaction { transaction_id } => body.write_u32(*transaction_id),
        }
        let mut out = ByteBuffer::new();
        out.write_u32((Self::HEADER_LENGTH + body.len()) as u32);
        out.write_u32(self.packet_type() as u32);
        out.write_bytes(body.bytes());
        out.into_bytes()
    }

    // MARK: Decoding

    /// Length of the next packet in `data`, or None when the header isn't there yet.
    pub fn frame_length(data: &[u8]) -> Option<usize> {
        let head: [u8; 4] = data.get(..4)?.try_into().ok()?;
        Some(u32::from_le_bytes(head) as usize)
    }

    /// Decode one complete packet from the front of `data`; returns the
    /// packet and the number of bytes consumed.
    pub fn decode(data: &[u8]) -> Result<(PtpIpPacket, usize), DecodeError> {
        if data.len() < Self::HEADER_LENGTH {
            return Err(DecodeError::NeedMoreBytes(Self::HEADER_LENGTH - data.len()));
        }
        let mut b = ByteBuffer::from(&data[..Self::HEADER_LENGTH]);
        let length = b.read_u32()?;
        if (length as usize) < Self::HEADER_LENGTH || length >= 1 << 30 {
            return Err(DecodeError::BadLength(length));
        }
        let length_usize = length as usize;
        if data.len() < length_usize {
            return Err(DecodeError::NeedMoreBytes(length_usize - data.len()));
        }
        let raw_type = b.read_u32()?;
        let ty = PtpIpPacketType::from_raw(raw_type).ok_or(DecodeError::UnknownType(raw_type))?;
        let mut body = ByteBuffer::from(&data[Self::HEADER_LENGTH..length_usize]);
        let packet = Self::decode_body(ty, &mut body)?;
        Ok((packet, length_usize))
    }

    fn decode_body(ty: PtpIpPacketType, body: &mut ByteBuffer) -> Result<Self, DecodeError> {
        use PtpIpPacketType as T;
        Ok(match ty {
            T::InitCommandRequest => {
                let guid = body.read_bytes(16)?;
                let name = body.read_utf16le_z()?;
                let protocol_version = if body.remaining() >= 4 {
                    body.read_u32()?
                } else {
                    Self::PROTOCOL_VERSION
                };
                Self::InitCommandRequest {
                    guid,
                    name,
                    protocol_version,
                }
            }
            T::InitCommandAck => {
                let connection_number = body.read_u32()?;
                let guid = body.read_bytes(16)?;
                let name = body.read_utf16le_z().unwrap_or_default();
                let protocol_version = if body.remaining() >= 4 {
                    body.read_u32()?
                } else {
                    Self::PROTOCOL_VERSION
                };
                Self::InitCommandAck {
                    connection_number,
                    guid,
                    name,
                    protocol_version,
                }
            }
            T::InitEventRequest => Self::InitEventRequest {
                connection_number: body.read_u32()?,
            },
            T::InitEventAck => Self::InitEventAck,
            T::InitFail => Self::InitFail {
                reason: if body.remaining() >= 4 {
                    body.read_u32()?
                } else {
                    0
                },
            },
            T::CmdRequest => {
                let data_phase = body.read_u32()?;
                let code = OperationCode(body.read_u16()?);
                let transaction_id = body.read_u32()?;
                Self::CmdRequest {
                    data_phase,
                    code,
                    transaction_id,
                    parameters: read_params(body),
                }
            }
            T::CmdResponse => {
                let code = ResponseCode(body.read_u16()?);
                let transaction_id = body.read_u32()?;
                Self::CmdResponse {
                    code,
                    transaction_id,
                    parameters: read_params(body),
                }
            }
            T::Event => {
                let code = EventCode(body.read_u16()?);
                let transaction_id = body.read_u32()?;
                Self::Event {
                    code,
                    transaction_id,
                    parameters: read_params(body),
                }
            }
            T::StartData => {
                let transaction_id = body.read_u32()?;
                Self::StartData {
                    transaction_id,
                    total_length: body.read_u64()?,
                }
            }
            T::Data => Self::Data {
                transaction_id: body.read_u32()?,
                payload: body.read_remaining(),
            },
            T::EndData => Self::EndData {
                transaction_id: body.read_u32()?,
                payload: body.read_remaining(),
            },
            T::CancelTransaction => Self::CancelTransaction {
                transaction_id: body.read_u32()?,
            },
            T::ProbeRequest => Self::ProbeRequest,
            T::ProbeResponse => Self::ProbeResponse,
        })
    }
}

fn pad16(g: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = g.iter().copied().take(16).collect();
    out.resize(16, 0);
    out
}

fn read_params(b: &mut ByteBuffer) -> Vec<u32> {
    let mut params = Vec::new();
    while b.remaining() >= 4 && params.len() < 5 {
        match b.read_u32() {
            Ok(v) => params.push(v),
            Err(_) => break,
        }
    }
    params
}

/// Accumulates bytes from a stream and yields complete packets.
#[derive(Debug, Clone, Default)]
pub struct PtpIpFramer {
    buffer: Vec<u8>,
}

impl PtpIpFramer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    /// Pops every complete packet currently buffered.
    pub fn drain(&mut self) -> Result<Vec<PtpIpPacket>, DecodeError> {
        let mut out = Vec::new();
        let mut start = 0;
        while let Some(len) = PtpIpPacket::frame_length(&self.buffer[start..]) {
            if self.buffer.len() - start < len || len < PtpIpPacket::HEADER_LENGTH {
                break;
            }
            match PtpIpPacket::decode(&self.buffer[start..]) {
                Ok((p, consumed)) => {
                    start += consumed;
                    out.push(p);
                }
                Err(e) => {
                    self.buffer.drain(..start);
                    return Err(e);
                }
            }
        }
        self.buffer.drain(..start);
        if let Some(len) = PtpIpPacket::frame_length(&self.buffer) {
            if len < PtpIpPacket::HEADER_LENGTH {
                return Err(DecodeError::BadLength(len as u32));
            }
        }
        Ok(out)
    }

    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len()
    }
}

/// Stable per-install GUID sent in InitCommandRequest. Cameras pair on it,
/// so it must not change between launches.
pub struct PtpIpIdentity;

impl PtpIpIdentity {
    pub fn guid(uuid: &Uuid) -> Vec<u8> {
        uuid.as_bytes().to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_command_round_trip() {
        let guid = PtpIpIdentity::guid(&Uuid::new_v4());
        let p = PtpIpPacket::InitCommandRequest {
            guid,
            name: "Tether".into(),
            protocol_version: PtpIpPacket::PROTOCOL_VERSION,
        };
        let enc = p.encode();
        // length(4) + type(4) + guid(16) + "Tether\0" utf16 (14) + version(4)
        assert_eq!(enc.len(), 8 + 16 + 14 + 4);
        assert_eq!(PtpIpPacket::frame_length(&enc), Some(enc.len()));
        let (dec, used) = PtpIpPacket::decode(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(used, enc.len());
    }

    #[test]
    fn command_and_data_packets() {
        let packets = vec![
            PtpIpPacket::CmdRequest {
                data_phase: 1,
                code: OperationCode::GET_OBJECT_INFO,
                transaction_id: 7,
                parameters: vec![0x1234],
            },
            PtpIpPacket::CmdResponse {
                code: ResponseCode::OK,
                transaction_id: 7,
                parameters: vec![],
            },
            PtpIpPacket::StartData {
                transaction_id: 7,
                total_length: 1000,
            },
            PtpIpPacket::Data {
                transaction_id: 7,
                payload: vec![1, 2, 3],
            },
            PtpIpPacket::EndData {
                transaction_id: 7,
                payload: vec![4, 5],
            },
            PtpIpPacket::Event {
                code: EventCode::OBJECT_ADDED,
                transaction_id: 0,
                parameters: vec![0x42, 0, 0],
            },
            PtpIpPacket::InitEventRequest {
                connection_number: 3,
            },
            PtpIpPacket::InitEventAck,
            PtpIpPacket::ProbeRequest,
            PtpIpPacket::ProbeResponse,
            PtpIpPacket::InitFail { reason: 2 },
            PtpIpPacket::CancelTransaction { transaction_id: 9 },
            PtpIpPacket::InitCommandAck {
                connection_number: 1,
                guid: vec![7; 16],
                name: "ILCE-7M4".into(),
                protocol_version: 0x10000,
            },
        ];
        for p in packets {
            let (d, _) = PtpIpPacket::decode(&p.encode()).unwrap();
            assert_eq!(d, p, "{:?}", p.packet_type());
        }
    }

    #[test]
    fn framer_splits_and_joins() {
        let a = PtpIpPacket::CmdResponse {
            code: ResponseCode::OK,
            transaction_id: 1,
            parameters: vec![5],
        }
        .encode();
        let b = PtpIpPacket::Event {
            code: EventCode::CAPTURE_COMPLETE,
            transaction_id: 0,
            parameters: vec![],
        }
        .encode();
        let all = [a, b].concat();
        let mut f = PtpIpFramer::new();
        f.append(&all[..5]);
        assert_eq!(f.drain().unwrap().len(), 0);
        f.append(&all[5..]);
        let out = f.drain().unwrap();
        assert_eq!(out.len(), 2);
        assert_eq!(
            out[1],
            PtpIpPacket::Event {
                code: EventCode::CAPTURE_COMPLETE,
                transaction_id: 0,
                parameters: vec![]
            }
        );
        assert_eq!(f.buffered_bytes(), 0);
    }

    #[test]
    fn bad_length_is_rejected() {
        let mut f = PtpIpFramer::new();
        f.append(&[2, 0, 0, 0, 6, 0, 0, 0]);
        assert!(f.drain().is_err());
    }

    #[test]
    fn truncated_body_and_unknown_type_are_errors() {
        // CmdResponse claiming 10 bytes: header + 2, too short for code + tid.
        assert_eq!(
            PtpIpPacket::decode(&[10, 0, 0, 0, 7, 0, 0, 0, 1, 0]),
            Err(DecodeError::Truncated)
        );
        assert_eq!(
            PtpIpPacket::decode(&[8, 0, 0, 0, 99, 0, 0, 0]),
            Err(DecodeError::UnknownType(99))
        );
        assert_eq!(
            PtpIpPacket::decode(&[12, 0, 0, 0, 7, 0]),
            Err(DecodeError::NeedMoreBytes(2))
        );
    }
}
