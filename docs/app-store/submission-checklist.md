# App Store submission checklist

## Done in the project

- [x] No unused background modes (removed `fetch` / `processing`; exports use
      the short time iOS gives any app when it goes to the background).
- [x] Privacy manifest `Tether/PrivacyInfo.xcprivacy`: no tracking, no data
      collected, file timestamps read only inside the app's container (C617.1).
- [x] Permission strings say exactly what each permission is used for.
- [x] Export to Photos works with add-only access (album only with full access).
- [x] A camera-free demo session on the Connect screen for App Review.
- [x] Local-network HTTP allowed for Wi-Fi cameras (`NSAllowsLocalNetworking`).
- [x] `ITSAppUsesNonExemptEncryption` = NO (only Apple's TLS, for FTPS).
- [x] Debug-only launch flags compile out of release builds.

## To do in App Store Connect

- [ ] Reserve the name. "Open Tether" may be taken; have a fallback ready.
- [ ] Privacy policy URL: host `privacy-policy.md` (fill in the support
      email first). GitHub Pages on the OpenTether repo works.
- [ ] Support URL: host `support.md` the same way.
- [ ] App Privacy: "Data Not Collected".
- [ ] Age rating questionnaire (no objectionable content: 4+).
- [ ] Category: Photo & Video.
- [ ] Screenshots: 6.9" iPhone and 13" iPad (the app supports iPad). The demo
      session gives good-looking frames without a camera.
- [ ] Description: name brands only to say what works ("works with Canon,
      Nikon, Sony…"). Keep brand names out of the app name, subtitle and
      keywords (guidelines 2.3.7, 5.2.1).
- [ ] Review notes: paste `review-notes.md` and attach a short screen
      recording of a real camera session.

## Mac (Mac Catalyst)

Open Tether ships on the Mac as a Mac Catalyst build of the same target, with
the same bundle ID, so one App Store record covers iPhone, iPad and Mac
(universal purchase).

Done in the project:

- [x] `SUPPORTS_MACCATALYST` on; "Designed for iPad" on Mac turned off (the
      Catalyst build replaces it); bundle ID not derived (`maccatalyst.` prefix
      off), so the Mac app joins the iOS record.
- [x] App Sandbox entitlements for the Mac only (`Tether/Tether-macOS.entitlements`,
      picked with `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`): network client and
      server (PTP/IP, FTP receiver on 2121 with passive 40000-40100, FTP export),
      USB, Photos, user-selected files read/write and app-scoped bookmarks.
      The iOS Wi-Fi info entitlement stays iOS-only. Hardened runtime on.
- [x] `LSApplicationCategoryType` = Photography (required for Mac apps).
- [x] Export folders use security-scoped bookmarks on the Mac so access
      survives relaunch.
- [x] Wi-Fi name: macOS gives Catalyst apps no way to read it, so the Mac
      build skips the location prompt, hides the onboarding row and points to
      the Wi-Fi menu instead. "Open Wi-Fi Settings" opens System Settings → Wi-Fi.
- [x] "Optimize Interface for Mac" (Mac idiom, `TARGETED_DEVICE_FAMILY[sdk=macosx*]`
      = 6): native Mac sizes instead of the iPad layout scaled to 77 %. Glass
      buttons and menus keep the iOS look (`macControlStyle`), toolbar icons
      use the neutral tint (`macToolbarTint`).
- [x] Window opens at 1280 × 820 (wide enough for the side-by-side shoot
      layout), minimum 800 × 600.
- [x] Keyboard: library shortcuts, plus Space / 0–5 / P / X / U / ← → on the
      shoot screen.

To do:

- [ ] Real USB session on the Mac with the R5 Mark II: detection, connect,
      capture, transfer (see the Mac test notes below).
- [ ] Copy pass: many strings say "phone" / "iPhone" ("Delete from iPhone",
      "On My iPhone › Exports", USB and FTP instructions). On the Mac they should
      say "Mac" (iPad already reads oddly). App Review rejects Mac apps that
      talk about an iPhone (guideline 2.3.10 / 4.0).
- [ ] App Store Connect: add the macOS platform to the app record, Mac
      screenshots (1280×800 minimum, 16:10), and a Mac build uploaded from
      an archive of the "My Mac (Mac Catalyst)" destination.
- [ ] App Privacy answers are the same as iOS; confirm the privacy manifest is
      bundled in the Mac build (it is part of the same target).
- [ ] Review notes: mention that the demo session works on the Mac too, and
      that a USB camera needs macOS's Image Capture / Photos not to grab it.

### Mac test notes

- macOS asks once for access to the camera ("would like to access … camera")
  through ImageCaptureCore; answer Allow.
- Quit Image Capture, Photos, Lightroom, Capture One and EOS Utility first:
  whichever opens the camera session first owns it.
- If Photos or Image Capture opens by itself when the camera is plugged in,
  set Image Capture → (camera) → "Connecting this camera opens: No application".

## Before submitting

- [ ] TestFlight round on more than one body (so far only a Canon EOS R5
      Mark II has been tried).
- [ ] Archive with the Release configuration and let Xcode validate it.
