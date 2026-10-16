# Building the Tether iOS app

The Xcode project is generated, not checked in.

```sh
brew install xcodegen
cd tether-ios
xcodegen generate          # writes Tether.xcodeproj from project.yml
open Tether.xcodeproj
```

`project.yml` declares two targets:

- **Tether** – the SwiftUI app (iOS 17+, bundle id `com.bradyjordan.tether`), depending on
  the local Swift package `Packages/TetherCore`.
- **TetherTests** – XCTest cases for the pure view-model logic.

## Signing

1. In Xcode select the `Tether` target → *Signing & Capabilities*.
2. Pick your team; signing style is *Automatic*. Alternatively set
   `DEVELOPMENT_TEAM` in `project.yml` under `settings.base` and regenerate.
3. The entitlements file `Tether/Tether.entitlements` requests only
   `com.apple.developer.networking.wifi-info` (Access Wi-Fi Information), which is
   needed to read the current SSID. Enable that capability on the App ID in the
   developer portal; nothing else is required.
4. Info.plist keys (camera, local network, Bonjour services, photo library add,
   location when-in-use, background modes, Files support) are generated from
   `project.yml` → `info.properties`. Edit them there, never in Xcode.

## Notes

- Run on a real device: ImageCaptureCore (USB-C) and Wi-Fi discovery do not work in the
  simulator.
- Open Tether has no server: everything runs on the device.
