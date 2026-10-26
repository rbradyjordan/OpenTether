//! Typed PTP values as carried in DevicePropDesc / DevicePropValue payloads.

use std::fmt;

use super::byte_buffer::ByteBuffer;
use super::codes::DataType;
use super::transaction::{PtpError, PtpResult};

/// A typed PTP value as carried in DevicePropDesc / DevicePropValue payloads.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum PtpValue {
    Int8(i8),
    UInt8(u8),
    Int16(i16),
    UInt16(u16),
    Int32(i32),
    UInt32(u32),
    Int64(i64),
    UInt64(u64),
    Int128 { low: u64, high: u64 },
    UInt128 { low: u64, high: u64 },
    Array(Vec<PtpValue>),
    String(String),
    Undefined,
}

impl PtpValue {
    pub fn data_type(&self) -> DataType {
        match self {
            Self::Int8(_) => DataType::INT8,
            Self::UInt8(_) => DataType::UINT8,
            Self::Int16(_) => DataType::INT16,
            Self::UInt16(_) => DataType::UINT16,
            Self::Int32(_) => DataType::INT32,
            Self::UInt32(_) => DataType::UINT32,
            Self::Int64(_) => DataType::INT64,
            Self::UInt64(_) => DataType::UINT64,
            Self::Int128 { .. } => DataType::INT128,
            Self::UInt128 { .. } => DataType::UINT128,
            Self::String(_) => DataType::STRING,
            Self::Undefined => DataType::UNDEF,
            Self::Array(a) => match a.first() {
                None => DataType::AUINT8,
                Some(first) => DataType(first.data_type().0 | 0x4000),
            },
        }
    }

    /// Integer view for numeric scalars (sign preserved); None for strings/arrays.
    pub fn int_value(&self) -> Option<i64> {
        match *self {
            Self::Int8(v) => Some(v.into()),
            Self::UInt8(v) => Some(v.into()),
            Self::Int16(v) => Some(v.into()),
            Self::UInt16(v) => Some(v.into()),
            Self::Int32(v) => Some(v.into()),
            Self::UInt32(v) => Some(v.into()),
            Self::Int64(v) => Some(v),
            Self::UInt64(v) => i64::try_from(v).ok(),
            _ => None,
        }
    }

    pub fn uint_value(&self) -> Option<u64> {
        match *self {
            Self::Int8(v) => u64::try_from(v).ok(),
            Self::UInt8(v) => Some(v.into()),
            Self::Int16(v) => u64::try_from(v).ok(),
            Self::UInt16(v) => Some(v.into()),
            Self::Int32(v) => u64::try_from(v).ok(),
            Self::UInt32(v) => Some(v.into()),
            Self::Int64(v) => u64::try_from(v).ok(),
            Self::UInt64(v) => Some(v),
            _ => None,
        }
    }

    pub fn string_value(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s),
            _ => None,
        }
    }

    // MARK: Wire coding

    pub fn read(data_type: DataType, buf: &mut ByteBuffer) -> PtpResult<PtpValue> {
        if data_type.is_array() {
            let n = buf.read_u32()? as usize;
            let mut items = Vec::with_capacity(n.min(1 << 16));
            for _ in 0..n {
                items.push(Self::read(data_type.scalar(), buf)?);
            }
            return Ok(Self::Array(items));
        }
        Ok(match data_type {
            DataType::INT8 => Self::Int8(buf.read_i8()?),
            DataType::UINT8 => Self::UInt8(buf.read_u8()?),
            DataType::INT16 => Self::Int16(buf.read_i16()?),
            DataType::UINT16 => Self::UInt16(buf.read_u16()?),
            DataType::INT32 => Self::Int32(buf.read_i32()?),
            DataType::UINT32 => Self::UInt32(buf.read_u32()?),
            DataType::INT64 => Self::Int64(buf.read_i64()?),
            DataType::UINT64 => Self::UInt64(buf.read_u64()?),
            DataType::INT128 => {
                let (low, high) = buf.read_u128_halves()?;
                Self::Int128 { low, high }
            }
            DataType::UINT128 => {
                let (low, high) = buf.read_u128_halves()?;
                Self::UInt128 { low, high }
            }
            DataType::STRING => Self::String(buf.read_ptp_string()?),
            other => return Err(PtpError::UnsupportedDataType(other)),
        })
    }

    pub fn write(&self, buf: &mut ByteBuffer) {
        match self {
            Self::Int8(v) => buf.write_i8(*v),
            Self::UInt8(v) => buf.write_u8(*v),
            Self::Int16(v) => buf.write_i16(*v),
            Self::UInt16(v) => buf.write_u16(*v),
            Self::Int32(v) => buf.write_i32(*v),
            Self::UInt32(v) => buf.write_u32(*v),
            Self::Int64(v) => buf.write_i64(*v),
            Self::UInt64(v) => buf.write_u64(*v),
            Self::Int128 { low, high } | Self::UInt128 { low, high } => {
                buf.write_u64(*low);
                buf.write_u64(*high);
            }
            Self::String(s) => buf.write_ptp_string(s),
            Self::Array(a) => {
                buf.write_u32(a.len() as u32);
                for v in a {
                    v.write(buf);
                }
            }
            Self::Undefined => {}
        }
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        self.write(&mut b);
        b.into_bytes()
    }

    /// Build a value of `data_type` from an integer (used when setting properties).
    pub fn make(data_type: DataType, v: i64) -> PtpValue {
        match data_type {
            DataType::INT8 => Self::Int8(v as i8),
            DataType::UINT8 => Self::UInt8(v as u8),
            DataType::INT16 => Self::Int16(v as i16),
            DataType::UINT16 => Self::UInt16(v as u16),
            DataType::INT32 => Self::Int32(v as i32),
            DataType::UINT32 => Self::UInt32(v as u32),
            DataType::INT64 => Self::Int64(v),
            DataType::UINT64 => Self::UInt64(v as u64),
            _ => Self::UInt32(v as u32),
        }
    }
}

impl fmt::Display for PtpValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::String(s) => write!(f, "\"{s}\""),
            Self::Array(a) => {
                let items: Vec<String> = a.iter().map(|v| v.to_string()).collect();
                write!(f, "[{}]", items.join(", "))
            }
            Self::Int128 { low, high } | Self::UInt128 { low, high } => {
                write!(f, "0x{high:016x}{low:016x}")
            }
            Self::Undefined => f.write_str("undef"),
            _ => match (self.int_value(), self.uint_value()) {
                (Some(i), _) => write!(f, "{i}"),
                (None, Some(u)) => write!(f, "{u}"),
                _ => f.write_str("?"),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_scalars_arrays_and_strings() {
        for v in [
            PtpValue::Int8(-3),
            PtpValue::UInt16(400),
            PtpValue::Int32(-1),
            PtpValue::UInt64(u64::MAX),
            PtpValue::UInt128 { low: 1, high: 2 },
            PtpValue::String("ISO".into()),
            PtpValue::Array(vec![PtpValue::UInt16(1), PtpValue::UInt16(2)]),
        ] {
            let mut b = ByteBuffer::from_bytes(v.encoded());
            assert_eq!(PtpValue::read(v.data_type(), &mut b).unwrap(), v);
        }
    }

    #[test]
    fn views_and_description() {
        assert_eq!(PtpValue::UInt64(u64::MAX).int_value(), None);
        assert_eq!(PtpValue::UInt64(u64::MAX).to_string(), u64::MAX.to_string());
        assert_eq!(PtpValue::Int16(-5).uint_value(), None);
        assert_eq!(PtpValue::make(DataType::UINT8, 300), PtpValue::UInt8(44));
        assert!(matches!(
            PtpValue::read(DataType(0x0042), &mut ByteBuffer::new()),
            Err(PtpError::UnsupportedDataType(_))
        ));
    }
}
