# Tether design system

The tether is the front door of a shoot. On set, the photographer looks at
the phone for a second between frames, in the dark, often one-handed, often
with a client over their shoulder. Every decision below follows from that.

## Principles

1. **The photograph is the interface.** Chrome recedes to near-black; nothing
   competes with the image. One accent colour, used for one thing: "this is
   live".
2. **Glanceable.** State is readable in under a second from arm's length:
   big numerals for exposure, a single status pill, download rings, no
   paragraphs on the shoot screen.
3. **Confidence through motion.** Every camera event has a physical echo:
   a frame *arrives* (slides in, settles), a capture *fires* (ring pulse plus
   haptic), a disconnect *dims* rather than alerts. Motion is short (120–280 ms),
   spring-based, and never decorative.
4. **Thumb-reachable.** Primary actions live in the bottom 40 % of the
   screen. The capture button is 72 pt and centred. Rating uses a swipe-up
   gesture on the filmstrip as well as taps.
5. **Honest.** Capabilities the camera lacks are hidden, not greyed. Errors
   say what to do next in one sentence. Nothing claims success before the
   bytes are on disk.

## Tokens (`Tether/Components/Theme.swift`)

### Colour
| Token | Light | Dark (default on shoot screens) | Use |
|-------|-------|--------------------------------|-----|
| `ink0` | `#0B0B0C` | `#F5F4F0` | primary text |
| `ink1` | `#4A4A4F` | `#B8B7B2` | secondary text |
| `ink2` | `#8A8A90` | `#7A7975` | tertiary / metadata |
| `surface0` | `#FFFFFF` | `#000000` | shoot canvas background (true black on OLED) |
| `surface1` | `#F6F5F2` | `#121214` | screens |
| `surface2` | `#ECEAE5` | `#1C1C20` | cards |
| `surface3` | `#E0DED8` | `#26262B` | raised / pressed |
| `hairline` | `rgba(0,0,0,.08)` | `rgba(255,255,255,.08)` | separators |
| `accent` | `#FF5A1F` | `#FF6A2C` | live, record, capture, selected |
| `accentSoft` | `rgba(255,90,31,.14)` | `rgba(255,106,44,.18)` | selection fills |
| `ok` | `#2BB673` | `#3DD68C` | connected, ready, delivered |
| `warn` | `#E8A317` | `#F2B63D` | battery low, watermark, warnings |
| `danger` | `#E23D3D` | `#FF5C5C` | disconnected, failed, reject |
| `pick` | `#FFC53D` | `#FFD166` | star fill |

Colour labels: red `#FF5C5C`, yellow `#FFD166`, green `#3DD68C`, blue `#4C8DFF`,
purple `#B07CFF` (same in both schemes).

### Type
System font (SF Pro) with these roles only; Dynamic Type via text styles,
numerals use `.monospacedDigit()`:

| Role | Style | Weight | Where |
|------|-------|--------|-------|
| `display` | 34 pt rounded | semibold | onboarding titles, empty states |
| `title` | 22 pt | semibold | screen titles |
| `headline` | 17 pt | semibold | card titles, camera name |
| `body` | 17 pt | regular | prose |
| `callout` | 15 pt | regular | descriptions |
| `caption` | 12 pt | medium, tracking +0.4, uppercase | labels above values |
| `exposure` | 20 pt rounded, mono digits | semibold | shutter / ƒ / ISO chips |
| `hud` | 13 pt mono digits | medium | status pill, filmstrip badges |

### Spacing and shape
4-pt grid: `xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`. Radii: `card 20`,
`control 14`, `chip 10`, `pill 999`. Hairline borders at 0.5 pt instead of
shadows in dark mode; a single 24-pt blur `rgba(0,0,0,.35)` shadow in light.

### Motion
| Name | Spring | Use |
|------|--------|-----|
| `snap` | response 0.28, damping 0.86 | selection, chips, toggles |
| `arrive` | response 0.42, damping 0.80 | new frame into filmstrip, cards |
| `settle` | response 0.55, damping 0.90 | sheets, canvas crossfade |
| `pulse` | 0.9 s ease-out, scale 1 → 1.6, opacity 0.6 → 0 | capture ring |

Reduce Motion: springs become 160 ms ease-out, the pulse becomes an opacity blink.

### Haptics
`capture` = rigid impact · `frameArrived` = soft impact · `rate` = selection
change · `pick/reject` = light impact · `connected` = success notification ·
`disconnected` = warning notification. Never more than one per event.

## Signature moments

- **Connect card stack.** Three cards (USB-C, Wi-Fi, FTP) with a live
  indicator that pulses once when a camera is actually visible on that path.
  USB-C card reads "Recommended · most stable" only when a device is on the bus.
- **The capture ring.** 72 pt circle, accent stroke. Tap: inner disc scales
  0.92 → 1 with a rigid haptic; a translucent ring expands outward (`pulse`).
  Long-press: ring turns hollow and labels "No AF".
- **Frame arrival.** New thumbnail slides in from the right at 0.9 scale with
  a progress ring filling clockwise as bytes land; on completion the ring
  flashes to `ok` and fades, the thumbnail settles to 1.0, and if "Show
  newest" is on the canvas crossfades (`settle`). With "Keep selection" a
  small count badge on the filmstrip increments instead.
- **Exposure chips.** Caption label above a big mono numeral
  (`1/250`, `ƒ/2.8`, `ISO 400`, `+0.3`). Tap opens a wheel-style picker that
  is the camera's own list; the current value is centred; haptic tick per
  step; changes apply on release.
- **Status pill.** One line: dot (ok/warn/danger) · camera model · transport
  glyph · battery · "3 ↓" while downloading. Tapping expands into the
  diagnostics sheet.
- **Rating.** Five 28-pt stars under the canvas; tap or drag across. Stars
  fill with `pick` and a selection tick. Pick (flag) and Reject (×) sit
  either side; reject dims the frame in the filmstrip to 40 %.
- **Client review.** True black, image only, gestures only. A 2-second
  hint "swipe · tap for name · hold corner to leave" fades on entry.
- **Disconnect.** The canvas dims to 60 %, the pill turns `danger`, and a
  bottom sheet slides up with the reconnect strategy in one sentence and one
  button. No modal alert.
- **Export quote.** A single line updates live as scope changes:
  "24 photos · 3 credits · 21 watermarked" with the watermark count in `warn`.

## Screens at a glance

Onboarding (3 pages, full-bleed imagery placeholder, one line each) →
Home (sessions as large cards with a 3-up thumbnail strip, resume banner on
top) → Connect hub → USB / Wi-Fi / FTP → Shoot → Loupe / Compare / Client
review → Looks sheet → Export sheet → Progress → Credits → Settings.

Light scheme is used for Home, Sessions, Settings, Credits; the dark
scheme is forced on Connect-progress, Shoot, Review and Looks regardless of
system setting (image-first screens).

## Accessibility

Every control has a label and a value; colour is never the only signal
(stars have a count, status has text); minimum hit target 44 pt; the
shoot screen's hidden-UI mode still exposes capture and rating to
VoiceOver via custom actions; Dynamic Type up to accessibility XL on every
screen except the canvas overlays, which cap at XXL.
