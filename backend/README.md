# tether-cloud

The small cloud half of **Tether**, the iOS camera-tethering app. Everything
photographic happens on the phone; this service only holds what cannot live
there:

- a **looks catalog** of 3D LUTs (`.cube`), generated procedurally at startup
- **AI colour match**: upload a reference and a target frame, get back a LUT
- a **credits / quota ledger** with the free-tier watermark rule
- **cloud batch export**: upload approved selects, download one zip
- the published **tested-camera matrix**

Single Rust crate (axum 0.8 + tokio, SQLite via `rusqlite` bundled, `image`
for JPEG/PNG, `zip` for downloads). No external services. The HTTP contract
the Swift client is written against is in [`API.md`](API.md).

## Run

```sh
cd backend
cargo run                       # http://127.0.0.1:8787, data in ./data/
```

| Env | Default | Meaning |
|-----|---------|---------|
| `TETHER_BIND` | `127.0.0.1:8787` | listen address |
| `TETHER_DB` | `./data/tether.db` | SQLite file (created, migrated on start) |
| `TETHER_STORAGE` | `./data/storage` | uploaded exports live under `exports/<batch>/` |
| `TETHER_DEV_PURCHASES` | unset | `1` trusts purchase requests without App Store verification (dev only) |
| `TETHER_ADMIN_TOKEN` | unset | enables `POST /v1/admin/credits/grant`; 503 when unset |
| `RUST_LOG` | `info,tower_http=info` | tracing filter |

Tokens are stored as SHA-256 only. JSON bodies are capped at 1 MiB, each
colour-match image at 12 MiB, each export item at 200 MiB (streamed to disk).
A background task runs hourly and expires batches (deletes files, marks
`expired`) seven days after completion.

## Check

```sh
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

Unit tests cover the LUT math (identity is exact, every output in `0..=1`,
`.cube` round-trip, red-fastest ordering), colour matching (same image ≈
identity, strength 0 = identity, dark→bright moves the mean, determinism) and
the watermark. `tests/api.rs` drives the router in-process against a temp
SQLite file through the whole contract.

## Endpoints with curl

Register a device (public):

```sh
curl -s localhost:8787/v1/devices/register -H 'content-type: application/json' \
  -d '{"device_id":"6f1c9d6e-0b4a-4c3e-9b1a-2f3e4d5c6b7a","platform":"ios","app_version":"1.0.0"}'
# {"token":"<43 chars>","account_id":"…","tier":"free","credits":{"balance":10,"monthly_grant":10,"renews_at":"…"}}
export TOK=…
```

Account and credits:

```sh
curl -s localhost:8787/v1/me -H "authorization: Bearer $TOK"
```

Looks catalog and a LUT (public; honours `If-None-Match`):

```sh
curl -s localhost:8787/v1/looks
curl -s -D- localhost:8787/v1/looks/film-warm.cube -o film-warm.cube
curl -s -o /dev/null -w '%{http_code}\n' localhost:8787/v1/looks/film-warm.cube \
  -H 'if-none-match: "<sha256 from the list>"'          # 304
```

Colour match (1 credit on the free tier, free on pro):

```sh
curl -s localhost:8787/v1/tone/color-match -H "authorization: Bearer $TOK" \
  -F reference=@reference.jpg -F target=@target.jpg -F strength=0.8 -F lut_size=33
# {"lut_id":"…","cube_url":"/v1/looks/<lut_id>.cube","sha256":"…","credits_charged":1,"credits_remaining":9,
#  "stats":{"reference_mean":[…],"target_mean":[…],"matched_mean":[…]}}
curl -s localhost:8787/v1/looks/<lut_id>.cube -H "authorization: Bearer $TOK"   # owner only
```

Batch export:

```sh
curl -s localhost:8787/v1/exports/batch -H "authorization: Bearer $TOK" -H 'content-type: application/json' -d '{
  "session_name":"Studio Day","watermark":false,"look_id":"film-warm",
  "items":[{"client_id":"a","filename":"IMG_0001.jpg","kind":"jpeg","bytes":4200000},
           {"client_id":"b","filename":"IMG_0001.CR3","kind":"raw","bytes":31000000}]}'
# {"batch_id":"<B>","items":[{"client_id":"a","item_id":"<I>","put_url":"/v1/exports/<B>/items/<I>","watermark":false},…],
#  "credits_charged":1,"credits_remaining":9}

curl -s -X PUT localhost:8787/v1/exports/<B>/items/<I> -H "authorization: Bearer $TOK" --data-binary @IMG_0001.jpg
curl -s -I localhost:8787/v1/exports/<B>/items/<I> -H "authorization: Bearer $TOK"     # 200 + Content-Length, or 404
curl -s -X POST localhost:8787/v1/exports/<B>/complete -H "authorization: Bearer $TOK"  # 409 items_missing until all stored
curl -s localhost:8787/v1/exports/<B> -H "authorization: Bearer $TOK"
curl -s localhost:8787/v1/exports/<B>/download -H "authorization: Bearer $TOK" -o studio-day.zip
```

Purchases (dev mode) and admin grant:

```sh
TETHER_DEV_PURCHASES=1 cargo run &
curl -s localhost:8787/v1/credits/purchase -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"product_id":"credits_50","transaction_id":"txn-123","signed_transaction":null}'
# repeat with the same transaction_id → same body with "replayed":true

TETHER_ADMIN_TOKEN=secret cargo run &
curl -s localhost:8787/v1/admin/credits/grant -H 'authorization: Bearer secret' -H 'content-type: application/json' \
  -d '{"account_id":"<account>","credits":25}'
```

Tested cameras and health (public):

```sh
curl -s localhost:8787/v1/cameras/tested
curl -s localhost:8787/healthz          # {"ok":true,"version":"0.1.0"}
```

## Layout

```
src/main.rs            config, listener, hourly expiry task
src/lib.rs             AppState, Config, router()
src/db.rs              SQLite schema (idempotent CREATE TABLE IF NOT EXISTS), ledger upkeep
src/auth.rs            Auth / MaybeAuth / Admin extractors, token hashing
src/error.rs           AppError → {"error","message"} JSON; Json extractor with JSON errors
src/looks.rs           Lut3d, 7 procedural looks, .cube writer/parser
src/colormatch.rs      CDF matching → LUT
src/watermark.rs       free-tier watermark (image crate only)
src/routes/*.rs        one file per resource
data/tested-cameras.json   served verbatim by /v1/cameras/tested
tests/api.rs           in-process HTTP contract tests
```

## Notes and limitations

- **Watermark** is a semi-transparent two-colour diagonal tile plus a solid
  badge rectangle bottom-right. There is no text: the crate deliberately
  depends on `image` alone (no `imageproc`, no font rasteriser). If a stored
  "JPEG" does not decode, the upload is kept unmodified and a warning is logged.
  RAW items are never watermarked (nothing can be burned into them), so their
  `watermark` flag is always `false`.
- **Purchases** are only applied with `TETHER_DEV_PURCHASES=1`. Without it the
  route returns `501 verification_not_configured`; the App Store Server API
  JWS check is marked `TODO(app-store-server-api)` in `src/routes/credits.rs`.
- **Expiry**: `expires_at` is set to creation + 7 days for open batches and reset
  to completion + 7 days on `complete`; the sweeper expires both.
- The `.cube` route matches `/v1/looks/{file}` and requires the `.cube` suffix
  itself (404 otherwise).
- Looks are re-seeded from the procedural definitions on every start
  (`INSERT … ON CONFLICT DO UPDATE`), so a changed formula ships automatically;
  bump `version` in `looks::CATALOG` when you change one.
