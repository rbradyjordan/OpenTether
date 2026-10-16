//! In-process HTTP contract tests: the router is driven with
//! `tower::ServiceExt::oneshot` against a temp SQLite file + storage dir.

use std::io::{Cursor, Read};

use axum::body::Body;
use axum::http::{header, Method, Request, StatusCode};
use axum::Router;
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tempfile::TempDir;
use tether_cloud::looks::Lut3d;
use tether_cloud::{router, AppState, Config};
use tower::ServiceExt;

struct App {
    router: Router,
    state: AppState,
    _dir: TempDir,
}

fn app_with(dev_purchases: bool, admin: Option<&str>) -> App {
    let dir = tempfile::tempdir().unwrap();
    let config = Config {
        bind: "127.0.0.1:0".parse().unwrap(),
        db_path: dir.path().join("tether.db"),
        storage: dir.path().join("storage"),
        dev_purchases,
        admin_token: admin.map(str::to_string),
    };
    let state = AppState::new(config).unwrap();
    App {
        router: router(state.clone()),
        state,
        _dir: dir,
    }
}

fn app() -> App {
    app_with(true, Some("admin-secret"))
}

struct Resp {
    status: StatusCode,
    headers: axum::http::HeaderMap,
    body: Vec<u8>,
}

impl Resp {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body)
            .unwrap_or_else(|e| panic!("not json ({e}): {}", String::from_utf8_lossy(&self.body)))
    }
    fn text(&self) -> String {
        String::from_utf8(self.body.clone()).unwrap()
    }
}

async fn send(app: &App, req: Request<Body>) -> Resp {
    let res = app.router.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let headers = res.headers().clone();
    let body = res.into_body().collect().await.unwrap().to_bytes().to_vec();
    Resp {
        status,
        headers,
        body,
    }
}

fn req(method: Method, uri: &str, token: Option<&str>) -> axum::http::request::Builder {
    let mut b = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        b = b.header(header::AUTHORIZATION, format!("Bearer {t}"));
    }
    b
}

async fn get(app: &App, uri: &str, token: Option<&str>) -> Resp {
    send(
        app,
        req(Method::GET, uri, token).body(Body::empty()).unwrap(),
    )
    .await
}

async fn post_json(app: &App, uri: &str, token: Option<&str>, body: Value) -> Resp {
    send(
        app,
        req(Method::POST, uri, token)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap(),
    )
    .await
}

async fn register(app: &App) -> (String, String) {
    let r = post_json(
        app,
        "/v1/devices/register",
        None,
        json!({"device_id": uuid::Uuid::new_v4().to_string(), "platform": "ios", "app_version": "1.0.0"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let v = r.json();
    (
        v["token"].as_str().unwrap().to_string(),
        v["account_id"].as_str().unwrap().to_string(),
    )
}

fn jpeg(w: u32, h: u32, rgb: [u8; 3]) -> Vec<u8> {
    let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(w, h, |x, _| {
        let shade = (x * 255 / w.max(1)) as u8;
        image::Rgb([rgb[0].saturating_add(shade / 4), rgb[1], rgb[2]])
    }));
    let mut buf = Cursor::new(Vec::new());
    img.write_to(&mut buf, image::ImageFormat::Jpeg).unwrap();
    buf.into_inner()
}

fn multipart(parts: &[(&str, Option<&str>, &[u8])]) -> (String, Vec<u8>) {
    let boundary = "----tetherboundary7MA4YWxk";
    let mut body = Vec::new();
    for (name, filename, data) in parts {
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        match filename {
            Some(f) => body.extend_from_slice(
                format!("Content-Disposition: form-data; name=\"{name}\"; filename=\"{f}\"\r\nContent-Type: application/octet-stream\r\n\r\n").as_bytes(),
            ),
            None => body.extend_from_slice(format!("Content-Disposition: form-data; name=\"{name}\"\r\n\r\n").as_bytes()),
        }
        body.extend_from_slice(data);
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

fn set_credits(app: &App, account: &str, credits: i64) {
    app.state
        .db
        .with(|c| {
            c.execute(
                "UPDATE accounts SET credits = ?2 WHERE id = ?1",
                rusqlite::params![account, credits],
            )
        })
        .unwrap();
}

// ---------------------------------------------------------------------------

#[tokio::test]
async fn healthz() {
    let app = app();
    let r = get(&app, "/healthz", None).await;
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(
        r.json(),
        json!({"ok": true, "version": env!("CARGO_PKG_VERSION")})
    );
}

#[tokio::test]
async fn register_then_me() {
    let app = app();
    let device = uuid::Uuid::new_v4().to_string();
    let r = post_json(
        &app,
        "/v1/devices/register",
        None,
        json!({"device_id": device, "platform": "ios", "app_version": "1.0.0"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK);
    let v = r.json();
    let token = v["token"].as_str().unwrap().to_string();
    assert_eq!(token.len(), 43);
    assert_eq!(v["tier"], "free");
    assert_eq!(v["credits"]["balance"], 10);
    assert_eq!(v["credits"]["monthly_grant"], 10);
    assert!(v["credits"]["renews_at"].as_str().is_some());
    uuid::Uuid::parse_str(v["account_id"].as_str().unwrap()).unwrap();

    let me = get(&app, "/v1/me", Some(&token)).await;
    assert_eq!(me.status, StatusCode::OK);
    let m = me.json();
    assert_eq!(m["account_id"], v["account_id"]);
    assert_eq!(m["tier"], "free");
    assert_eq!(m["credits"]["balance"], 10);
    assert_eq!(m["watermark_required"], false);

    // Re-register the same device: same account, new token, old token revoked.
    let r2 = post_json(
        &app,
        "/v1/devices/register",
        None,
        json!({"device_id": device, "platform": "ios", "app_version": "1.0.1"}),
    )
    .await;
    let v2 = r2.json();
    assert_eq!(v2["account_id"], v["account_id"]);
    let token2 = v2["token"].as_str().unwrap();
    assert_ne!(token2, token);
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.status,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        get(&app, "/v1/me", Some(token2)).await.status,
        StatusCode::OK
    );

    // Validation
    let bad = post_json(
        &app,
        "/v1/devices/register",
        None,
        json!({"device_id": "not-a-uuid", "platform": "ios", "app_version": "1"}),
    )
    .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
    assert_eq!(bad.json()["error"], "invalid_device_id");
}

#[tokio::test]
async fn unauthorized_paths() {
    let app = app();
    for (m, uri) in [
        (Method::GET, "/v1/me"),
        (Method::POST, "/v1/tone/color-match"),
        (Method::POST, "/v1/exports/batch"),
        (
            Method::GET,
            "/v1/exports/00000000-0000-0000-0000-000000000000",
        ),
        (Method::POST, "/v1/credits/purchase"),
    ] {
        let r = send(&app, req(m.clone(), uri, None).body(Body::empty()).unwrap()).await;
        assert_eq!(r.status, StatusCode::UNAUTHORIZED, "{m} {uri}");
        assert_eq!(r.json()["error"], "unauthorized");
        let r = send(
            &app,
            req(m.clone(), uri, Some("bogus"))
                .body(Body::empty())
                .unwrap(),
        )
        .await;
        assert_eq!(r.status, StatusCode::UNAUTHORIZED, "{m} {uri} bogus token");
    }
    // Public routes need no token.
    assert_eq!(get(&app, "/v1/looks", None).await.status, StatusCode::OK);
    assert_eq!(
        get(&app, "/v1/cameras/tested", None).await.status,
        StatusCode::OK
    );
    assert_eq!(
        get(&app, "/v1/looks/neutral.cube", None).await.status,
        StatusCode::OK
    );
    // Unknown route is JSON 404.
    let r = get(&app, "/v1/nope", None).await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
    assert_eq!(r.json()["error"], "not_found");
}

#[tokio::test]
async fn watermark_required_and_monthly_grant() {
    let app = app();
    let (token, account) = register(&app).await;
    set_credits(&app, &account, 0);
    let m = get(&app, "/v1/me", Some(&token)).await.json();
    assert_eq!(m["watermark_required"], true);

    // Push renews_at into the past: the next request tops up to the grant.
    let past = (Utc::now() - Duration::days(40)).to_rfc3339();
    app.state
        .db
        .with(|c| {
            c.execute(
                "UPDATE accounts SET renews_at = ?2, credits = 3 WHERE id = ?1",
                rusqlite::params![account, past],
            )
        })
        .unwrap();
    let m = get(&app, "/v1/me", Some(&token)).await.json();
    assert_eq!(m["credits"]["balance"], 10, "top-up, not additive");
    let renews =
        chrono::DateTime::parse_from_rfc3339(m["credits"]["renews_at"].as_str().unwrap()).unwrap();
    assert!(renews > Utc::now());
    assert_eq!(m["watermark_required"], false);
}

#[tokio::test]
async fn looks_list_and_cube_etag() {
    let app = app();
    let r = get(&app, "/v1/looks", None).await;
    let looks = r.json()["looks"].as_array().unwrap().clone();
    assert_eq!(looks.len(), 7);
    let ids: Vec<&str> = looks.iter().map(|l| l["id"].as_str().unwrap()).collect();
    assert_eq!(
        ids,
        [
            "neutral",
            "portrait-soft",
            "film-warm",
            "film-cool",
            "mono-classic",
            "teal-orange",
            "high-key"
        ]
    );
    for l in &looks {
        assert_eq!(l["size"], 33);
        assert_eq!(l["version"], 1);
        assert_eq!(l["sha256"].as_str().unwrap().len(), 64);
        assert_eq!(
            l["cube_url"],
            format!("/v1/looks/{}.cube", l["id"].as_str().unwrap())
        );
        assert!(
            l["hint"]["warmth"].is_number()
                && l["hint"]["contrast"].is_number()
                && l["hint"]["saturation"].is_number()
        );
        assert!(["neutral", "portrait", "film", "mono", "cinematic"]
            .contains(&l["family"].as_str().unwrap()));
    }

    let sha = looks[0]["sha256"].as_str().unwrap().to_string();
    let r = get(&app, "/v1/looks/neutral.cube", None).await;
    assert_eq!(r.status, StatusCode::OK);
    assert!(r.headers[header::CONTENT_TYPE]
        .to_str()
        .unwrap()
        .starts_with("text/plain"));
    let etag = r.headers[header::ETAG].to_str().unwrap().to_string();
    assert_eq!(etag, format!("\"{sha}\""));
    let text = r.text();
    assert_eq!(Lut3d::sha256_hex_of(&text), sha);
    assert!(
        text.starts_with("TITLE \"Neutral\"\nLUT_3D_SIZE 33\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n")
    );
    let (title, lut) = Lut3d::parse_cube(&text).unwrap();
    assert_eq!(title, "Neutral");
    assert_eq!(lut, Lut3d::identity(33));

    let r = send(
        &app,
        req(Method::GET, "/v1/looks/neutral.cube", None)
            .header(header::IF_NONE_MATCH, &etag)
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_MODIFIED);
    assert!(r.body.is_empty());

    assert_eq!(
        get(&app, "/v1/looks/missing.cube", None).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        get(&app, "/v1/looks/neutral", None).await.status,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn color_match_charges_and_lut_is_retrievable() {
    let app = app();
    let (token, account) = register(&app).await;
    let reference = jpeg(300, 200, [220, 160, 90]);
    let target = jpeg(240, 160, [60, 80, 120]);
    let (ct, body) = multipart(&[
        ("reference", Some("ref.jpg"), &reference),
        ("target", Some("tgt.jpg"), &target),
        ("strength", None, b"0.8"),
        ("lut_size", None, b"17"),
    ]);
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct)
            .body(Body::from(body.clone()))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let v = r.json();
    assert_eq!(v["credits_charged"], 1);
    assert_eq!(v["credits_remaining"], 9);
    let lut_id = v["lut_id"].as_str().unwrap();
    assert_eq!(v["cube_url"], format!("/v1/looks/{lut_id}.cube"));
    for k in ["reference_mean", "target_mean", "matched_mean"] {
        assert_eq!(v["stats"][k].as_array().unwrap().len(), 3);
    }
    assert!(
        v["stats"]["matched_mean"][0].as_f64().unwrap()
            > v["stats"]["target_mean"][0].as_f64().unwrap()
    );

    // Owner can fetch it, it parses, and it stays out of the public catalog.
    let cube = get(&app, v["cube_url"].as_str().unwrap(), Some(&token)).await;
    assert_eq!(cube.status, StatusCode::OK);
    assert_eq!(
        cube.headers[header::ETAG].to_str().unwrap(),
        format!("\"{}\"", v["sha256"].as_str().unwrap())
    );
    let (_, lut) = Lut3d::parse_cube(&cube.text()).unwrap();
    assert_eq!(lut.size, 17);
    assert!(lut
        .data
        .iter()
        .all(|c| c.iter().all(|v| (0.0..=1.0).contains(v))));
    assert_eq!(
        get(&app, v["cube_url"].as_str().unwrap(), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    let (other, _) = register(&app).await;
    assert_eq!(
        get(&app, v["cube_url"].as_str().unwrap(), Some(&other))
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        get(&app, "/v1/looks", None).await.json()["looks"]
            .as_array()
            .unwrap()
            .len(),
        7
    );
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.json()["credits"]["balance"],
        9
    );

    // Out of credits → 402; pro → free of charge.
    set_credits(&app, &account, 0);
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct)
            .body(Body::from(body.clone()))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::PAYMENT_REQUIRED);
    assert_eq!(r.json()["error"], "insufficient_credits");
    post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "pro_monthly", "transaction_id": "t-pro-1"}),
    )
    .await;
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct)
            .body(Body::from(body.clone()))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(r.json()["credits_charged"], 0);

    // Bad inputs.
    let (ct2, body2) = multipart(&[
        ("reference", Some("r"), b"not an image"),
        ("target", Some("t"), &target),
    ]);
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct2)
            .body(Body::from(body2))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    assert_eq!(r.json()["error"], "invalid_image");
    let (ct3, body3) = multipart(&[
        ("reference", Some("r"), &reference),
        ("target", Some("t"), &target),
        ("lut_size", None, b"25"),
    ]);
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct3)
            .body(Body::from(body3))
            .unwrap(),
    )
    .await;
    assert_eq!(r.json()["error"], "invalid_lut_size");
}

#[tokio::test]
async fn color_match_rejects_oversized_upload() {
    let app = app();
    let (token, _) = register(&app).await;
    let big = vec![0u8; 12 * 1024 * 1024 + 1];
    let (ct, body) = multipart(&[("reference", Some("r"), &big), ("target", Some("t"), b"x")]);
    let r = send(
        &app,
        req(Method::POST, "/v1/tone/color-match", Some(&token))
            .header(header::CONTENT_TYPE, &ct)
            .body(Body::from(body))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(r.json()["error"], "payload_too_large");
}

async fn put_item(app: &App, token: &str, url: &str, bytes: Vec<u8>) -> Resp {
    send(
        app,
        req(Method::PUT, url, Some(token))
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(Body::from(bytes))
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn export_batch_credits_watermark_upload_and_zip() {
    let app = app();
    let (token, account) = register(&app).await;
    set_credits(&app, &account, 2);

    let r = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({
            "session_name": "Studio Day",
            "watermark": false,
            "look_id": "film-warm",
            "items": [
                {"client_id": "a", "filename": "IMG_0001.jpg", "kind": "jpeg", "bytes": 1000},
                {"client_id": "b", "filename": "IMG_0001.CR3", "kind": "raw", "bytes": 1000},
                {"client_id": "c", "filename": "IMG_0002.jpg", "kind": "jpeg", "bytes": 1000},
                {"client_id": "d", "filename": "IMG_0003.jpg", "kind": "jpeg", "bytes": 1000}
            ]
        }),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let v = r.json();
    let batch = v["batch_id"].as_str().unwrap().to_string();
    assert_eq!(v["credits_charged"], 2);
    assert_eq!(v["credits_remaining"], 0);
    let items = v["items"].as_array().unwrap();
    assert_eq!(items.len(), 4);
    let wm: Vec<bool> = items
        .iter()
        .map(|i| i["watermark"].as_bool().unwrap())
        .collect();
    assert_eq!(
        wm,
        [false, false, false, true],
        "two JPEGs paid, RAW free, third JPEG watermarked"
    );
    for (i, it) in items.iter().enumerate() {
        assert_eq!(it["client_id"], ["a", "b", "c", "d"][i]);
        assert_eq!(
            it["put_url"],
            format!(
                "/v1/exports/{batch}/items/{}",
                it["item_id"].as_str().unwrap()
            )
        );
    }

    // HEAD before upload → 404; complete before upload → 409 listing the ids.
    let url_a = items[0]["put_url"].as_str().unwrap();
    let r = send(
        &app,
        req(Method::HEAD, url_a, Some(&token))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
    let r = post_json(
        &app,
        &format!("/v1/exports/{batch}/complete"),
        Some(&token),
        json!({}),
    )
    .await;
    assert_eq!(r.status, StatusCode::CONFLICT);
    assert_eq!(r.json()["error"], "items_missing");
    assert!(r.json()["message"]
        .as_str()
        .unwrap()
        .contains(items[0]["item_id"].as_str().unwrap()));

    // Upload: a plain JPEG, a RAW blob, another JPEG, and the watermarked JPEG.
    let plain = jpeg(400, 300, [90, 140, 200]);
    let raw = vec![7u8; 5000];
    let r = put_item(&app, &token, url_a, plain.clone()).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.json()["status"], "stored");
    assert_eq!(r.json()["bytes"], plain.len());
    let r = put_item(
        &app,
        &token,
        items[1]["put_url"].as_str().unwrap(),
        raw.clone(),
    )
    .await;
    assert_eq!(r.json()["bytes"], raw.len());
    put_item(
        &app,
        &token,
        items[2]["put_url"].as_str().unwrap(),
        plain.clone(),
    )
    .await;
    let r = put_item(
        &app,
        &token,
        items[3]["put_url"].as_str().unwrap(),
        plain.clone(),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK);
    let marked_len = r.json()["bytes"].as_u64().unwrap();
    assert_ne!(
        marked_len as usize,
        plain.len(),
        "watermarked copy is re-encoded"
    );

    // HEAD after upload reports the stored length.
    let r = send(
        &app,
        req(Method::HEAD, url_a, Some(&token))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(
        r.headers[header::CONTENT_LENGTH].to_str().unwrap(),
        plain.len().to_string()
    );

    // Download before completion is a 409.
    let r = get(&app, &format!("/v1/exports/{batch}/download"), Some(&token)).await;
    assert_eq!(r.status, StatusCode::CONFLICT);

    let r = post_json(
        &app,
        &format!("/v1/exports/{batch}/complete"),
        Some(&token),
        json!({}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let s = r.json();
    assert_eq!(s["status"], "complete");
    assert_eq!(s["download_url"], format!("/v1/exports/{batch}/download"));

    let r = get(&app, &format!("/v1/exports/{batch}"), Some(&token)).await;
    let s = r.json();
    assert_eq!(s["batch_id"], batch);
    assert_eq!(s["session_name"], "Studio Day");
    assert_eq!(s["status"], "complete");
    assert!(s["expires_at"].as_str().is_some());
    let si = s["items"].as_array().unwrap();
    assert_eq!(si.len(), 4);
    assert_eq!(si[0]["filename"], "IMG_0001.jpg");
    assert_eq!(si[0]["bytes_expected"], 1000);
    assert_eq!(si[0]["bytes_stored"], plain.len());
    assert_eq!(si[3]["watermark"], true);
    assert_eq!(si[3]["bytes_stored"], marked_len);

    // After completion the batch no longer accepts uploads.
    let r = put_item(&app, &token, url_a, plain.clone()).await;
    assert_eq!(r.status, StatusCode::CONFLICT);
    assert_eq!(r.json()["error"], "batch_complete");

    // Zip contains every stored file, uncompressed.
    let r = get(&app, &format!("/v1/exports/{batch}/download"), Some(&token)).await;
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(r.headers[header::CONTENT_TYPE], "application/zip");
    let mut archive = zip::ZipArchive::new(Cursor::new(r.body.clone())).unwrap();
    assert_eq!(archive.len(), 4);
    let mut names: Vec<String> = (0..archive.len())
        .map(|i| archive.by_index(i).unwrap().name().unwrap().to_string())
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            "IMG_0001.CR3",
            "IMG_0001.jpg",
            "IMG_0002.jpg",
            "IMG_0003.jpg"
        ]
    );
    {
        let mut f = archive.by_name("IMG_0001.jpg").unwrap();
        assert_eq!(f.compression(), zip::CompressionMethod::Stored);
        let mut data = Vec::new();
        f.read_to_end(&mut data).unwrap();
        assert_eq!(data, plain);
    }
    {
        let mut f = archive.by_name("IMG_0001.CR3").unwrap();
        let mut data = Vec::new();
        f.read_to_end(&mut data).unwrap();
        assert_eq!(data, raw);
    }
    {
        let mut f = archive.by_name("IMG_0003.jpg").unwrap();
        let mut data = Vec::new();
        f.read_to_end(&mut data).unwrap();
        assert_eq!(data.len() as u64, marked_len);
        let img = image::load_from_memory(&data).unwrap().to_rgb8();
        // Badge plate in the bottom-right corner is the solid dark colour.
        let p = img.get_pixel(400 - 8 - 2, 300 - 8 - 2);
        assert!(
            p.0[0] < 40 && p.0[1] < 40 && p.0[2] < 48,
            "badge missing: {:?}",
            p.0
        );
    }

    // Another account can't see the batch.
    let (other, _) = register(&app).await;
    assert_eq!(
        get(&app, &format!("/v1/exports/{batch}"), Some(&other))
            .await
            .status,
        StatusCode::NOT_FOUND
    );

    // Expiry sweep: nothing yet, then everything once 7 days have passed.
    assert_eq!(
        tether_cloud::routes::exports::expire_once(&app.state, Utc::now())
            .await
            .unwrap(),
        0
    );
    let later = Utc::now() + Duration::days(8);
    assert_eq!(
        tether_cloud::routes::exports::expire_once(&app.state, later)
            .await
            .unwrap(),
        1
    );
    let s = get(&app, &format!("/v1/exports/{batch}"), Some(&token))
        .await
        .json();
    assert_eq!(s["status"], "expired");
    assert!(s["download_url"].is_null());
    assert!(!app
        .state
        .config
        .storage
        .join("exports")
        .join(&batch)
        .exists());
    let r = send(
        &app,
        req(Method::HEAD, url_a, Some(&token))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn export_batch_pro_and_forced_watermark_rules() {
    let app = app();
    let (token, account) = register(&app).await;
    set_credits(&app, &account, 0);

    // Free with zero credits: everything JPEG is watermarked, nothing charged.
    let v = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "watermark": false, "look_id": null,
               "items": [{"client_id": "a", "filename": "a.jpg", "kind": "jpeg", "bytes": 10},
                         {"client_id": "b", "filename": "b.dng", "kind": "raw", "bytes": 10}]}),
    )
    .await
    .json();
    assert_eq!(v["credits_charged"], 0);
    assert_eq!(v["items"][0]["watermark"], true);
    assert_eq!(v["items"][1]["watermark"], false);

    // Pro: never charged, never watermarked unless asked.
    post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "pro_monthly", "transaction_id": "pro-x"}),
    )
    .await;
    let v = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "watermark": false, "look_id": null,
               "items": [{"client_id": "a", "filename": "a.jpg", "kind": "jpeg", "bytes": 10}]}),
    )
    .await
    .json();
    assert_eq!(v["credits_charged"], 0);
    assert_eq!(v["items"][0]["watermark"], false);
    let v = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "watermark": true, "look_id": null,
               "items": [{"client_id": "a", "filename": "a.jpg", "kind": "jpeg", "bytes": 10}]}),
    )
    .await
    .json();
    assert_eq!(
        v["items"][0]["watermark"], true,
        "watermark:true forces it on"
    );

    // Validation.
    let r = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "items": []}),
    )
    .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    let r = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "items": [{"client_id": "a", "filename": "a", "kind": "tiff", "bytes": 1}]}),
    )
    .await;
    assert_eq!(r.json()["error"], "invalid_kind");
    let r = post_json(
        &app,
        "/v1/exports/batch",
        Some(&token),
        json!({"session_name": "s", "look_id": "nope", "items": [{"client_id": "a", "filename": "a", "kind": "raw", "bytes": 1}]}),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn purchase_dev_mode_and_replay() {
    let app = app();
    let (token, _) = register(&app).await;
    let r = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "credits_50", "transaction_id": "tx-1", "signed_transaction": null}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let v = r.json();
    assert_eq!(v["tier"], "free");
    assert_eq!(v["credits"]["balance"], 60);
    assert_eq!(v["replayed"], false);

    let r = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "credits_50", "transaction_id": "tx-1"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK);
    let v = r.json();
    assert_eq!(v["credits"]["balance"], 60, "replay does not re-apply");
    assert_eq!(v["replayed"], true);
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.json()["credits"]["balance"],
        60
    );

    let v = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "credits_200", "transaction_id": "tx-2"}),
    )
    .await
    .json();
    assert_eq!(v["credits"]["balance"], 260);

    let v = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "pro_monthly", "transaction_id": "tx-3"}),
    )
    .await
    .json();
    assert_eq!(v["tier"], "pro");
    let me = get(&app, "/v1/me", Some(&token)).await.json();
    assert_eq!(me["tier"], "pro");
    assert_eq!(me["watermark_required"], false);

    let r = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "gold", "transaction_id": "tx-4"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    assert_eq!(r.json()["error"], "unknown_product");

    // Someone else replaying our transaction id is a conflict.
    let (other, _) = register(&app).await;
    let r = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&other),
        json!({"product_id": "credits_50", "transaction_id": "tx-1"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn pro_expires_lazily() {
    let app = app();
    let (token, account) = register(&app).await;
    post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "pro_monthly", "transaction_id": "p1"}),
    )
    .await;
    let past = (Utc::now() - Duration::hours(1)).to_rfc3339();
    app.state
        .db
        .with(|c| {
            c.execute(
                "UPDATE accounts SET pro_until = ?2 WHERE id = ?1",
                rusqlite::params![account, past],
            )
        })
        .unwrap();
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.json()["tier"],
        "free"
    );
}

#[tokio::test]
async fn purchase_without_dev_mode_is_501() {
    let app = app_with(false, None);
    let (token, _) = register(&app).await;
    let r = post_json(
        &app,
        "/v1/credits/purchase",
        Some(&token),
        json!({"product_id": "credits_50", "transaction_id": "tx-1", "signed_transaction": "eyJ..."}),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_IMPLEMENTED);
    assert_eq!(r.json()["error"], "verification_not_configured");
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.json()["credits"]["balance"],
        10
    );

    // Admin disabled when the token is unset.
    let r = post_json(
        &app,
        "/v1/admin/credits/grant",
        Some("whatever"),
        json!({"account_id": "x", "credits": 1}),
    )
    .await;
    assert_eq!(r.status, StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn admin_grant() {
    let app = app();
    let (token, account) = register(&app).await;
    let r = post_json(
        &app,
        "/v1/admin/credits/grant",
        Some("admin-secret"),
        json!({"account_id": account, "credits": 25}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.json()["credits"]["balance"], 35);
    assert_eq!(
        get(&app, "/v1/me", Some(&token)).await.json()["credits"]["balance"],
        35
    );

    let r = post_json(
        &app,
        "/v1/admin/credits/grant",
        Some("wrong"),
        json!({"account_id": account, "credits": 25}),
    )
    .await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
    let r = post_json(
        &app,
        "/v1/admin/credits/grant",
        Some(&token),
        json!({"account_id": account, "credits": 25}),
    )
    .await;
    assert_eq!(
        r.status,
        StatusCode::UNAUTHORIZED,
        "a device token is not the admin token"
    );
    let r = post_json(
        &app,
        "/v1/admin/credits/grant",
        Some("admin-secret"),
        json!({"account_id": "nope", "credits": 1}),
    )
    .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn cameras_tested() {
    let app = app();
    let r = get(&app, "/v1/cameras/tested", None).await;
    assert_eq!(r.status, StatusCode::OK);
    let v = r.json();
    assert!(v["updated_at"].as_str().is_some());
    let cams = v["cameras"].as_array().unwrap();
    assert!(cams.len() >= 20);
    for c in cams {
        assert!(["verified", "reported", "planned"].contains(&c["status"].as_str().unwrap()));
        assert_eq!(
            c["status"], "planned",
            "nothing is verified yet: {}",
            c["model"]
        );
        for t in c["transports"].as_array().unwrap() {
            assert!(["usb", "ptpip"].contains(&t.as_str().unwrap()));
        }
        assert!(c["notes"].as_str().is_some() && c["vendor"].as_str().is_some());
    }
    assert!(cams
        .iter()
        .any(|c| c["model"] == "Q3" && c["transports"] == json!(["usb"])));
}

#[tokio::test]
async fn json_body_limit_and_bad_json() {
    let app = app();
    let (token, _) = register(&app).await;
    let r = send(
        &app,
        req(Method::POST, "/v1/exports/batch", Some(&token))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from("{not json"))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    assert_eq!(r.json()["error"], "invalid_json");
    let huge = format!(
        "{{\"session_name\":\"{}\",\"items\":[]}}",
        "x".repeat(1024 * 1024 + 10)
    );
    let r = send(
        &app,
        req(Method::POST, "/v1/exports/batch", Some(&token))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(huge))
            .unwrap(),
    )
    .await;
    assert_eq!(r.status, StatusCode::PAYLOAD_TOO_LARGE);
}
