//! Platform adapters (`Tether/Adapters/`): the Keychain for FTP passwords
//! and the Photos library for exports.

pub mod keychain;
pub mod photos;

pub use keychain::{KeychainSecrets, MemorySecrets, SecretStore};
pub use photos::{PhotoLibrary, SystemPhotoLibrary};
