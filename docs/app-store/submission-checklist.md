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
- [ ] Mac availability: decide whether to offer the iPad app on Apple silicon
      Macs (see the Mac notes in the session summary) or untick it for now.

## Before submitting

- [ ] TestFlight round on more than one body (so far only a Canon EOS R5
      Mark II has been tried).
- [ ] Archive with the Release configuration and let Xcode validate it.
