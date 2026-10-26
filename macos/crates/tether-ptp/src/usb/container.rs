//! PTP-over-USB generic container, USB authorization state and bus
//! candidates. Portable: no ImageCaptureCore here.

use tether_types::CameraVendor;

use crate::ptp::{
    ByteBuffer, EventCode, OperationCode, PtpError, PtpEvent, PtpResponse, PtpResult, ResponseCode,
};

/// Container type in the USB generic container header.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u16)]
pub enum ContainerType {
    Undefined = 0,
    Command = 1,
    Data = 2,
    Response = 3,
    Event = 4,
}

impl ContainerType {
    pub fn from_raw(v: u16) -> Option<Self> {
        Some(match v {
            0 => Self::Undefined,
            1 => Self::Command,
            2 => Self::Data,
            3 => Self::Response,
            4 => Self::Event,
            _ => return None,
        })
    }
}

/// PTP-over-USB "generic container" (PIMA 15740 USB class spec §5): the
/// framing `ICCameraDevice.requestSendPTPCommand` expects for the command and
/// returns for the response, and the framing of `didReceivePTPEvent` data.
///
/// ```text
/// u32 length (header included) · u16 type · u16 code · u32 transactionID · payload/params
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpUsbContainer {
    pub container_type: ContainerType,
    pub code: u16,
    pub transaction_id: u32,
    pub payload: Vec<u8>,
}

impl PtpUsbContainer {
    pub const HEADER_LENGTH: usize = 12;

    pub fn new(
        container_type: ContainerType,
        code: u16,
        transaction_id: u32,
        payload: Vec<u8>,
    ) -> Self {
        Self {
            container_type,
            code,
            transaction_id,
            payload,
        }
    }

    pub fn command(code: OperationCode, transaction_id: u32, parameters: &[u32]) -> Self {
        let mut b = ByteBuffer::new();
        parameters.iter().for_each(|p| b.write_u32(*p));
        Self::new(
            ContainerType::Command,
            code.0,
            transaction_id,
            b.into_bytes(),
        )
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u32((Self::HEADER_LENGTH + self.payload.len()) as u32);
        b.write_u16(self.container_type as u16);
        b.write_u16(self.code);
        b.write_u32(self.transaction_id);
        b.write_bytes(&self.payload);
        b.into_bytes()
    }

    /// Parses one container. The payload ends at the declared length, or at
    /// the end of `data` when the declared length overruns it.
    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        if data.len() < Self::HEADER_LENGTH {
            return Err(PtpError::Malformed(format!(
                "USB container shorter than header ({} bytes)",
                data.len()
            )));
        }
        let mut b = ByteBuffer::from(&data[..Self::HEADER_LENGTH]);
        let length = b.read_u32()? as usize;
        let raw_type = b.read_u16()?;
        let container_type = ContainerType::from_raw(raw_type)
            .ok_or_else(|| PtpError::Malformed(format!("unknown container type {raw_type}")))?;
        let code = b.read_u16()?;
        let transaction_id = b.read_u32()?;
        let end = data.len().min(length.max(Self::HEADER_LENGTH));
        Ok(Self {
            container_type,
            code,
            transaction_id,
            payload: data[Self::HEADER_LENGTH..end].to_vec(),
        })
    }

    /// Up to five u32 parameters from a response/event payload.
    pub fn parameters(&self) -> Vec<u32> {
        let (chunks, _) = self.payload.as_chunks::<4>();
        chunks
            .iter()
            .take(5)
            .map(|c| u32::from_le_bytes(*c))
            .collect()
    }

    pub fn as_response(&self) -> Option<PtpResponse> {
        (self.container_type == ContainerType::Response).then(|| PtpResponse {
            code: ResponseCode(self.code),
            parameters: self.parameters(),
            data_in: Vec::new(),
            transaction_id: self.transaction_id,
        })
    }

    pub fn as_event(&self) -> Option<PtpEvent> {
        (self.container_type == ContainerType::Event).then(|| {
            PtpEvent::new(EventCode(self.code), self.parameters())
                .with_transaction_id(self.transaction_id)
        })
    }
}

/// One authorization's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Grant {
    NotDetermined,
    Granted,
    Denied,
    NotRequired,
}

impl Grant {
    /// Raw values match the iOS enum.
    pub fn raw(self) -> &'static str {
        match self {
            Self::NotDetermined => "notDetermined",
            Self::Granted => "granted",
            Self::Denied => "denied",
            Self::NotRequired => "notRequired",
        }
    }

    fn allows(self) -> bool {
        matches!(self, Self::Granted | Self::NotRequired)
    }

    fn missing(self) -> bool {
        matches!(self, Self::Denied | Self::NotDetermined)
    }
}

/// Which authorizations ImageCaptureCore granted. Both are required to send
/// raw PTP where the system has them (iOS 18.3+); elsewhere they are
/// `NotRequired`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UsbAuthorizationState {
    pub control: Grant,
    pub contents: Grant,
}

impl Default for UsbAuthorizationState {
    fn default() -> Self {
        Self {
            control: Grant::NotDetermined,
            contents: Grant::NotDetermined,
        }
    }
}

impl UsbAuthorizationState {
    pub fn new(control: Grant, contents: Grant) -> Self {
        Self { control, contents }
    }

    /// Refused before: only System Settings can change it now.
    pub fn is_denied(&self) -> bool {
        self.control == Grant::Denied || self.contents == Grant::Denied
    }

    pub fn can_send_ptp(&self) -> bool {
        self.control.allows() && self.contents.allows()
    }

    pub fn summary(&self) -> String {
        if self.can_send_ptp() {
            return "Camera control and contents access granted".into();
        }
        let mut missing = Vec::new();
        if self.control.missing() {
            missing.push("camera control");
        }
        if self.contents.missing() {
            missing.push("camera access");
        }
        if self.is_denied() {
            return format!("Turned off: allow {} in Settings", missing.join(" and "));
        }
        format!("Needs {}", missing.join(" and "))
    }
}

/// A camera seen on the USB bus before we open it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UsbCameraCandidate {
    /// ICDevice UUID string.
    pub id: String,
    pub name: String,
    pub usb_vendor_id: i32,
    pub usb_product_id: i32,
    pub serial_number: Option<String>,
    pub vendor_guess: CameraVendor,
    pub has_open_session: bool,
}

impl UsbCameraCandidate {
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        usb_vendor_id: i32,
        usb_product_id: i32,
        serial_number: Option<String>,
        has_open_session: bool,
    ) -> Self {
        let vendor_guess = CameraVendor::ALL
            .into_iter()
            .find(|v| v.usb_vendor_id().map(i32::from) == Some(usb_vendor_id))
            .unwrap_or(CameraVendor::Generic);
        Self {
            id: id.into(),
            name: name.into(),
            usb_vendor_id,
            usb_product_id,
            serial_number,
            vendor_guess,
            has_open_session,
        }
    }
}

/// Hex strings for the USB IDs the setup guides show: `0x04A9`.
pub fn usb_id_hex(v: i32) -> String {
    format!("0x{v:04X}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_encodes_header_and_params() {
        let c = PtpUsbContainer::command(OperationCode::GET_OBJECT_INFO, 7, &[0x1234]);
        let enc = c.encode();
        assert_eq!(
            enc,
            vec![16, 0, 0, 0, 1, 0, 0x08, 0x10, 7, 0, 0, 0, 0x34, 0x12, 0, 0]
        );
        assert_eq!(PtpUsbContainer::parse(&enc).unwrap(), c);
    }

    #[test]
    fn decodes_response_and_event() {
        let r = PtpUsbContainer::new(
            ContainerType::Response,
            0x2001,
            9,
            vec![5, 0, 0, 0, 6, 0, 0, 0],
        );
        let resp = PtpUsbContainer::parse(&r.encode())
            .unwrap()
            .as_response()
            .unwrap();
        assert_eq!(resp.code, ResponseCode::OK);
        assert_eq!(resp.parameters, vec![5, 6]);
        assert_eq!(resp.transaction_id, 9);
        assert!(r.as_event().is_none());

        let e = PtpUsbContainer::new(ContainerType::Event, 0x4002, 0, vec![0x77, 0, 0, 0]);
        let ev = PtpUsbContainer::parse(&e.encode())
            .unwrap()
            .as_event()
            .unwrap();
        assert_eq!(ev.code, EventCode::OBJECT_ADDED);
        assert_eq!(ev.parameters, vec![0x77]);
    }

    #[test]
    fn tolerates_bad_lengths_without_panicking() {
        assert!(PtpUsbContainer::parse(&[1, 2, 3]).is_err());
        // Declared length larger than the data: payload clipped to what's there.
        let mut d =
            PtpUsbContainer::new(ContainerType::Response, 0x2001, 1, vec![1, 0, 0, 0]).encode();
        d[0] = 200;
        assert_eq!(
            PtpUsbContainer::parse(&d).unwrap().payload,
            vec![1, 0, 0, 0]
        );
        // Declared length shorter than the header: empty payload.
        d[0] = 2;
        assert!(PtpUsbContainer::parse(&d).unwrap().payload.is_empty());
        // Unknown type.
        d[4] = 9;
        assert!(matches!(
            PtpUsbContainer::parse(&d),
            Err(PtpError::Malformed(_))
        ));
        // More than five params and a ragged tail are ignored.
        let c = PtpUsbContainer::new(ContainerType::Event, 0x4002, 0, vec![1; 27]);
        assert_eq!(c.parameters().len(), 5);
    }

    #[test]
    fn authorization_summary() {
        let ok = UsbAuthorizationState::new(Grant::NotRequired, Grant::Granted);
        assert!(ok.can_send_ptp());
        let denied = UsbAuthorizationState::new(Grant::Denied, Grant::Granted);
        assert_eq!(
            denied.summary(),
            "Turned off: allow camera control in Settings"
        );
        assert_eq!(
            UsbAuthorizationState::default().summary(),
            "Needs camera control and camera access"
        );
    }

    #[test]
    fn candidate_guesses_vendor_from_usb_id() {
        let c = UsbCameraCandidate::new("id", "EOS R5", 0x04A9, 0x32F4, None, false);
        assert_eq!(c.vendor_guess, CameraVendor::Canon);
        let r = UsbCameraCandidate::new("id", "GR", 0x25FB, 1, None, false);
        assert_eq!(r.vendor_guess, CameraVendor::Ricoh);
        assert_eq!(
            UsbCameraCandidate::new("id", "?", 0x1234, 1, None, false).vendor_guess,
            CameraVendor::Generic
        );
        assert_eq!(usb_id_hex(0x4A9), "0x04A9");
    }
}
