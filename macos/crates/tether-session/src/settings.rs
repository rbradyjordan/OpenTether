//! Small persisted preferences (`Tether/App/AppSettings.swift`), backed by
//! the store's `settings` table under the iOS keys.

use serde::{Deserialize, Serialize};
use tether_library::SessionStore;

mod keys {
    pub const FTP_USERNAME: &str = "ftp.username";
    pub const FTP_PASSWORD: &str = "ftp.password";
    pub const FTP_PORT: &str = "ftp.port";
    pub const ONBOARDED: &str = "onboarding.done";
    pub const AUTO_START_FTP: &str = "ftp.autostart";
    pub const PREFERRED_LIVE_VIEW: &str = "liveview.quality";
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    /// Credentials cameras use to push to the built-in FTP server.
    pub ftp_username: String,
    pub ftp_password: String,
    pub ftp_port: u16,
    pub has_onboarded: bool,
    /// Rust addition: start the FTP receiver at launch.
    pub auto_start_ftp: bool,
    /// Rust addition: live view quality ("low" | "medium" | "high").
    pub live_view_quality: tether_types::LiveViewQuality,
}

impl AppSettings {
    /// Loads, generating (and saving) a random FTP password the first time.
    pub fn load(store: &SessionStore) -> Self {
        let password = match store.setting(keys::FTP_PASSWORD) {
            Some(p) => p,
            None => {
                let p = random_password();
                store.set_setting(keys::FTP_PASSWORD, Some(&p));
                p
            }
        };
        Self {
            ftp_username: store
                .setting(keys::FTP_USERNAME)
                .unwrap_or_else(|| "tether".into()),
            ftp_password: password,
            ftp_port: store
                .setting(keys::FTP_PORT)
                .and_then(|s| s.parse().ok())
                .unwrap_or(2121),
            has_onboarded: store.setting(keys::ONBOARDED).as_deref() == Some("1"),
            auto_start_ftp: store.setting(keys::AUTO_START_FTP).as_deref() == Some("1"),
            live_view_quality: store
                .setting(keys::PREFERRED_LIVE_VIEW)
                .and_then(|s| serde_json::from_str(&format!("\"{s}\"")).ok())
                .unwrap_or(tether_types::LiveViewQuality::Medium),
        }
    }

    pub fn save(&self, store: &SessionStore) {
        store.set_setting(keys::FTP_USERNAME, Some(&self.ftp_username));
        store.set_setting(keys::FTP_PASSWORD, Some(&self.ftp_password));
        store.set_setting(keys::FTP_PORT, Some(&self.ftp_port.to_string()));
        store.set_setting(
            keys::ONBOARDED,
            Some(if self.has_onboarded { "1" } else { "0" }),
        );
        store.set_setting(
            keys::AUTO_START_FTP,
            Some(if self.auto_start_ftp { "1" } else { "0" }),
        );
        let q = serde_json::to_string(&self.live_view_quality).unwrap_or_default();
        store.set_setting(keys::PREFERRED_LIVE_VIEW, Some(q.trim_matches('"')));
    }
}

/// Eight characters from an alphabet without look-alikes (no 0/o, 1/l/i).
pub fn random_password() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    uuid::Uuid::new_v4()
        .as_bytes()
        .iter()
        .take(8)
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_persist_and_round_trip() {
        let store = SessionStore::in_memory().unwrap();
        let a = AppSettings::load(&store);
        assert_eq!(a.ftp_username, "tether");
        assert_eq!(a.ftp_port, 2121);
        assert_eq!(a.ftp_password.len(), 8);
        assert_eq!(AppSettings::load(&store).ftp_password, a.ftp_password);
        let mut b = a.clone();
        b.ftp_port = 2222;
        b.has_onboarded = true;
        b.live_view_quality = tether_types::LiveViewQuality::High;
        b.save(&store);
        assert_eq!(AppSettings::load(&store), b);
    }
}
