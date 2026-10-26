//! Secrets by key (`KeychainStore.swift`): FTP destination passwords live
//! in the macOS Keychain as generic passwords, never in the database.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::error::lock;

pub trait SecretStore: Send + Sync {
    fn read(&self, key: &str) -> Option<String>;
    /// `None` deletes the item.
    fn write(&self, key: &str, value: Option<&str>);
}

/// Generic-password Keychain items under one service name.
#[derive(Debug, Clone)]
pub struct KeychainSecrets {
    pub service: String,
}

impl KeychainSecrets {
    pub const DEFAULT_SERVICE: &'static str = "com.bradyjordan.tether";

    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }
}

impl Default for KeychainSecrets {
    fn default() -> Self {
        Self::new(Self::DEFAULT_SERVICE)
    }
}

#[cfg(target_os = "macos")]
impl SecretStore for KeychainSecrets {
    fn read(&self, key: &str) -> Option<String> {
        security_framework::passwords::get_generic_password(&self.service, key)
            .ok()
            .and_then(|d| String::from_utf8(d).ok())
    }

    fn write(&self, key: &str, value: Option<&str>) {
        let _ = security_framework::passwords::delete_generic_password(&self.service, key);
        if let Some(v) = value {
            if let Err(e) = security_framework::passwords::set_generic_password(
                &self.service,
                key,
                v.as_bytes(),
            ) {
                tracing::warn!("Keychain write for {key} failed: {e}");
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
impl SecretStore for KeychainSecrets {
    fn read(&self, _key: &str) -> Option<String> {
        None
    }

    fn write(&self, _key: &str, _value: Option<&str>) {}
}

/// In-memory secrets (tests, previews).
#[derive(Debug, Default)]
pub struct MemorySecrets {
    items: Mutex<HashMap<String, String>>,
}

impl SecretStore for MemorySecrets {
    fn read(&self, key: &str) -> Option<String> {
        lock(&self.items).get(key).cloned()
    }

    fn write(&self, key: &str, value: Option<&str>) {
        let mut items = lock(&self.items);
        match value {
            Some(v) => {
                items.insert(key.to_string(), v.to_string());
            }
            None => {
                items.remove(key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_secrets_round_trip() {
        let s = MemorySecrets::default();
        s.write("ftp.1", Some("pw"));
        assert_eq!(s.read("ftp.1").as_deref(), Some("pw"));
        s.write("ftp.1", None);
        assert!(s.read("ftp.1").is_none());
    }
}
