# CLAUDE.md — Tether

Tether is Brady's iOS camera-tethering app. Read `README.md` first, then
`docs/BLUEPRINT.md` (Brady's blueprint, the source of truth; don't edit it),
`docs/DESIGN.md` and `docs/INTEROP.md` as your task needs.

It moved here from `rbradyjordan/personal-access-system-` (where it lived
under `tether-ios/`) with its history; paths in old commits carry that prefix.

| Piece | Where | Verified by |
|-------|-------|-------------|
| Engine: PTP engine, PTP/IP, ImageCaptureCore USB, 8 vendor handlers, discovery, FTP server/client, capture pipeline, SQLite store, looks, export queue, cloud client, diagnostics | `Packages/TetherCore/` | `swift test` on Linux |
| SwiftUI app, every screen | `Tether/`, `project.yml` (xcodegen) | only `swiftc -parse`d |
| `tether-cloud` backend: looks, colour match, credits, batch export | `backend/` | `cargo test` |

**Never run against a real camera or in Xcode yet.** CI runs only when
started by hand from the Actions tab.
