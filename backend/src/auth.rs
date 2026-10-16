//! Bearer-token auth. Tokens are 32 random bytes, base64url without padding
//! (43 chars); only their SHA-256 is stored.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use base64::Engine;
use chrono::Utc;
use sha2::{Digest, Sha256};

use crate::db::Account;
use crate::error::AppError;
use crate::AppState;

pub fn new_token() -> String {
    let bytes: [u8; 32] = rand::random();
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn hash_token(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

pub fn bearer(parts: &Parts) -> Option<&str> {
    parts
        .headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

/// Resolves the bearer token to an account (with lazy ledger upkeep applied).
pub fn authenticate(state: &AppState, parts: &Parts) -> Result<Option<Account>, AppError> {
    let Some(token) = bearer(parts) else {
        return Ok(None);
    };
    let Some(acct) = state.db.account_by_token_hash(&hash_token(token))? else {
        return Ok(None);
    };
    Ok(Some(state.db.refresh_account(acct, Utc::now())?))
}

/// Required auth: 401 `unauthorized` when the token is missing or unknown.
pub struct Auth(pub Account);

impl FromRequestParts<AppState> for Auth {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        match authenticate(state, parts)? {
            Some(acct) => Ok(Auth(acct)),
            None => Err(AppError::unauthorized()),
        }
    }
}

/// Optional auth for public routes that reveal more to the owner (match LUTs).
pub struct MaybeAuth(pub Option<Account>);

impl FromRequestParts<AppState> for MaybeAuth {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Ok(MaybeAuth(authenticate(state, parts)?))
    }
}

/// Admin routes: `Authorization: Bearer $TETHER_ADMIN_TOKEN`.
pub struct Admin;

impl FromRequestParts<AppState> for Admin {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let Some(expected) = state.config.admin_token.as_deref() else {
            return Err(AppError::new(
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                "admin_disabled",
                "TETHER_ADMIN_TOKEN is not set",
            ));
        };
        match bearer(parts) {
            Some(given) if constant_time_eq(given.as_bytes(), expected.as_bytes()) => Ok(Admin),
            _ => Err(AppError::unauthorized()),
        }
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_43_urlsafe_chars() {
        let t = new_token();
        assert_eq!(t.len(), 43);
        assert!(t
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
        assert_ne!(t, new_token());
    }

    #[test]
    fn hash_is_sha256_hex() {
        assert_eq!(hash_token("abc").len(), 64);
        assert_eq!(
            hash_token("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
