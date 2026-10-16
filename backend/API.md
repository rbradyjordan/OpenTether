# Tether cloud API (v1)

Base URL: `http://<host>:8787`. All request and response bodies are JSON
unless stated. All timestamps are RFC 3339 (UTC).

## Auth

Every `/v1/*` route **except** `POST /v1/devices/register`,
`GET /v1/cameras/tested`, `GET /v1/looks`, `GET /v1/looks/{id}.cube` and
`GET /healthz` requires

```
Authorization: Bearer <device_token>
```

Missing or unknown token → `401 {"error":"unauthorized","message":"…"}`.

## Errors

Every error is

```json
{"error": "<snake_case_code>", "message": "<human text>"}
```

with a fitting status: 400 (`invalid_json`, `invalid_device_id`,
`unsupported_platform`, `invalid_multipart`, `invalid_image`,
`invalid_strength`, `invalid_lut_size`, `missing_field`, `no_items`,
`too_many_items`, `invalid_kind`, `invalid_bytes`, `invalid_client_id`,
`invalid_session_name`, `unknown_product`, `invalid_transaction_id`,
`invalid_credits`, `upload_interrupted`, `empty_body`), 401 (`unauthorized`),
402 (`insufficient_credits`), 404 (`not_found`), 409 (`items_missing`,
`batch_complete`, `batch_expired`, `batch_not_complete`,
`transaction_conflict`), 413 (`payload_too_large`), 501
(`verification_not_configured`), 503 (`admin_disabled`), 500 (`internal`).

Limits: JSON bodies ≤ 1 MiB; each colour-match image ≤ 12 MiB; each export
item ≤ 200 MiB.

---

## 1. `POST /v1/devices/register` (public)

```json
{"device_id":"<uuid string>","platform":"ios","app_version":"1.0.0"}
```

→ `200`

```json
{"token":"<opaque 43-char urlsafe>","account_id":"<uuid>","tier":"free",
 "credits":{"balance":10,"monthly_grant":10,"renews_at":"<rfc3339>"}}
```

One account per `device_id`. Re-registering returns the same `account_id`
with a **new** token and revokes every previous token. New accounts are
`free` with 10 credits and a monthly grant of 10.

## 2. `GET /v1/me`

```json
{"account_id":"<uuid>","tier":"free"|"pro",
 "credits":{"balance":int,"monthly_grant":int,"renews_at":rfc3339|null},
 "watermark_required":bool}
```

`watermark_required` = `tier == "free" && balance == 0`.

Monthly grant: on any authenticated request, if `renews_at` has passed the
balance is topped **up to** `monthly_grant` (not added) and `renews_at` rolls
forward one month. A `pro` account whose `pro_until` has passed is downgraded
to `free` the same lazy way.

## 3. `GET /v1/looks` (public)

```json
{"looks":[{"id":"film-warm","name":"Film Warm","family":"neutral|portrait|film|mono|cinematic",
           "version":1,"size":33,"sha256":"<hex>","cube_url":"/v1/looks/film-warm.cube",
           "hint":{"warmth":f32,"contrast":f32,"saturation":f32}}]}
```

Seven catalog looks, seeded at startup: `neutral`, `portrait-soft`,
`film-warm`, `film-cool`, `mono-classic`, `teal-orange`, `high-key`. Only
catalog looks are listed; colour-match results are not.

## 4. `GET /v1/looks/{id}.cube` (public for catalog looks)

`200 text/plain; charset=utf-8`, Adobe `.cube`:

```
TITLE "<name>"
LUT_3D_SIZE N
DOMAIN_MIN 0 0 0
DOMAIN_MAX 1 1 1
r g b          ← N³ lines, 6 decimals, RED varies fastest, then green, then blue
```

Headers: `ETag: "<sha256>"`. `If-None-Match` with that value → `304`.
Colour-match results (family `match`) are served from the same route but
only to the owning account (bearer token required); anyone else gets `404`.

## 5. `POST /v1/tone/color-match`

`multipart/form-data` fields: `reference` (JPEG/PNG bytes), `target`
(JPEG/PNG bytes), optional `strength` (text, `0..1`, default `1.0`), optional
`lut_size` (`17` or `33`, default `33`). Each image ≤ 12 MiB (`413`).

Charges **1 credit** on the free tier (`402 insufficient_credits` when the
balance is 0); pro accounts are not charged.

Algorithm (deterministic): downscale both to ≤ 256 px on the long edge;
per-channel 256-bin CDFs; for each target level `t` the smallest reference
level `r` with `cdf_ref(r) ≥ cdf_target(t)`; 5-tap moving average; blend with
identity by `strength`; evaluate per-channel at every grid node; store as a
`.cube` with family `match`.

→ `200`

```json
{"lut_id":"<uuid>","cube_url":"/v1/looks/<lut_id>.cube","sha256":"<hex>",
 "credits_charged":0|1,"credits_remaining":int,
 "stats":{"reference_mean":[r,g,b],"target_mean":[r,g,b],"matched_mean":[r,g,b]}}
```

## 6. Batch export

### `POST /v1/exports/batch`

```json
{"session_name":"Studio Day","watermark":false,"look_id":"film-warm"|null,
 "items":[{"client_id":"a","filename":"IMG_0001.jpg","kind":"jpeg"|"raw","bytes":4200000}]}
```

→ `200`

```json
{"batch_id":"<uuid>",
 "items":[{"client_id":"a","item_id":"<uuid>","put_url":"/v1/exports/<batch>/items/<item>","watermark":false}],
 "credits_charged":int,"credits_remaining":int}
```

Credit rule: free tier pays 1 credit per **JPEG** item in order (RAW items
are free); once the balance hits 0 the remaining JPEG items are still accepted
but flagged `"watermark": true`. Pro pays nothing and is never watermarked.
`"watermark": true` in the request forces the flag on for JPEG items. RAW
items are never flagged (a watermark cannot be burned into them). `look_id`
must be a catalog look or one of the caller's match LUTs (`404` otherwise).
Up to 500 items per batch.

### `PUT /v1/exports/{batch}/items/{item}`

Raw file body (≤ 200 MiB, streamed to disk under
`$TETHER_STORAGE/exports/<batch>/`). → `200`

```json
{"item_id":"<uuid>","status":"stored","bytes":int}
```

`bytes` is the stored size. When the item is flagged `watermark` and is a
JPEG, the stored copy is re-encoded with the watermark burned in (so `bytes`
differs from the upload). Uploading to a completed batch → `409 batch_complete`.

### `HEAD /v1/exports/{batch}/items/{item}`

`200` with `Content-Length: <stored bytes>` once stored, `404` otherwise (lets
the client skip finished items when resuming).

### `POST /v1/exports/{batch}/complete`

Marks the batch complete when every item is stored and returns the batch
status (below). Otherwise `409 items_missing`; the `message` lists the missing
item ids. Idempotent once complete.

### `GET /v1/exports/{batch}`

```json
{"batch_id":"<uuid>","session_name":"Studio Day","status":"open"|"complete"|"expired",
 "items":[{"item_id":"<uuid>","client_id":"a","filename":"IMG_0001.jpg",
           "bytes_expected":int,"bytes_stored":int,"watermark":bool}],
 "download_url":"/v1/exports/<batch>/download"|null,
 "expires_at":"<rfc3339>"}
```

`bytes_stored` is `0` until the item is uploaded. `download_url` is non-null
only while `status == "complete"`.

### `GET /v1/exports/{batch}/download`

`200 application/zip` (streamed; entries are **stored**, not compressed) with
every stored item under its `filename`. `409 batch_not_complete` while open,
`409 batch_expired` afterwards.

Batches expire **7 days after completion** (open batches 7 days after
creation): an hourly background task deletes the files and sets
`status: "expired"`.

## 7. `POST /v1/credits/purchase`

```json
{"product_id":"credits_50"|"credits_200"|"pro_monthly","transaction_id":"…","signed_transaction":string|null}
```

Idempotent on `transaction_id`: a replay returns the original result with
`"replayed": true`. A different account replaying the same id → `409
transaction_conflict`.

With `TETHER_DEV_PURCHASES=1` the purchase is trusted: `credits_50` → +50,
`credits_200` → +200, `pro_monthly` → tier `pro` for 31 days (extends an
active pro period). Without it → `501 verification_not_configured`
(`TODO(app-store-server-api)`: verify the JWS `signed_transaction`).

→ `200`

```json
{"tier":"free"|"pro","credits":{"balance":int,"monthly_grant":int,"renews_at":rfc3339|null},"replayed":bool}
```

## 8. `POST /v1/admin/credits/grant`

`Authorization: Bearer $TETHER_ADMIN_TOKEN` (`503 admin_disabled` when unset,
`401` on a wrong token).

```json
{"account_id":"<uuid>","credits":25}
```

→ `200 {"account_id":"<uuid>","tier":"free"|"pro","credits":{…}}`. Negative
amounts deduct (floored at 0). Unknown account → `404`.

## 9. `GET /v1/cameras/tested` (public)

```json
{"updated_at":"<rfc3339>",
 "cameras":[{"vendor":"canon","model":"EOS R5","transports":["usb","ptpip"],
             "status":"verified"|"reported"|"planned","notes":"…"}]}
```

Served from `data/tested-cameras.json`. Everything is currently `planned`:
nothing has been verified against hardware yet.

## 10. `GET /healthz` (public)

```json
{"ok":true,"version":"<crate version>"}
```
