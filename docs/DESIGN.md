# Open Tether design system

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
Open Tether is **always dark**: graphite, brushed steel and a lens-blue accent,
taken from the app icon. `TetherApp` pins the colour scheme; every token has
one value.

| Token | Value | Use |
|-------|-------|-----|
| `ink0` | `#F2F4F7` | primary text |
| `ink1` | `#A9B0BB` | secondary text |
| `ink2` | `#6B7380` | tertiary / metadata |
| `surface0` | `#000000` | shoot canvas (true black on OLED) |
| `surface1` | `#0A0B0E` | screens (under `ScreenBackground`) |
| `surface2` | `#14161B` | cards, list rows |
| `surface3` | `#1E2128` | raised / pressed, fields |
| `hairline` | `rgba(255,255,255,.09)` | separators |
| `steel` | `#8C939E` | brushed-steel neutral |
| `accent` | `#4A9DFF` | live, capture, selected, primary actions |
| `accentDeep` | `#2F6FF0` | bottom of the accent gradient |
| `accentSoft` | `rgba(74,157,255,.16)` | selection fills |
| `ok` | `#3DD68C` | connected, ready, delivered |
| `warn` | `#F2B63D` | battery low, warnings |
| `danger` | `#FF5C5C` | disconnected, failed, reject |
| `pick` | `#FFD166` | star fill |

Surfaces are **flat Liquid Glass** (`glassEffect`, iOS 26+; a flat
ultra-thin material before that): no gradients, no drop shadows, no bevelled
edges. Glass sits on the ambient `ScreenBackground` so it has colour to bend.

Colour labels: red `#FF5C5C`, yellow `#FFD166`, green `#3DD68C`, blue `#4C8DFF`,
purple `#B07CFF`.

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
`control 14`, `chip 10`, `pill 999`. Cards are glass (`.tetherCard()` /
`.tetherGlassCard()`); things that sit on glass (icon tiles, fields, chips)
are flat translucent fills, never glass on glass.

### Components (`Components/Surfaces.swift`)
- `ScreenBackground` / `.tetherScreen()`: graphite with a faint blue glow from
  the top; every non-canvas screen. `.tetherList()` does the same for lists
  and forms.
- `.tetherGlass(in:tint:interactive:)`: the one glass primitive.
- `.tetherPrimary` / `.tetherSecondary` button styles: accent-tinted glass
  capsule; clear glass capsule with an accent label. Interactive glass, sized
  by `controlSize`.
- `IconTile`: symbol in a flat rounded tile (accent fill when active) for hub
  cards, settings rows and section headers.
- `.textFieldStyle(.tether)` and `LabeledField`: flat translucent fields with a
  caption label, so a filled-in value still says what it is.
- `.staggeredAppear(i)`: card stacks rise in one after another.
- `ScreenIntro`: one line under a large title saying what to do here.

Titles use SF Pro Rounded bold (navigation bars and display text).

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
- **Export summary.** A single line updates live as scope changes:
  "24 photos · 6 RAW → JPEG".

## Screens at a glance

Onboarding (welcome → camera brand and EOS model → connection → tailored
setup with the camera's own screens drawn and Canon pairing explained →
live permissions → workflow defaults → hands-on tour → connect, demo or
look around) →
Home (sessions as large cards with a 3-up thumbnail strip, resume banner on
top) → Connect hub → USB / Wi-Fi / FTP → Shoot → Loupe / Compare / Client
review → Looks sheet → Export sheet → Progress → Settings.

Every screen is dark. The splash shows the app icon with a blue bloom and a
light sweep, then fades into the app once launch work is done.

## Accessibility

Every control has a label and a value; colour is never the only signal
(stars have a count, status has text); minimum hit target 44 pt; the
shoot screen's hidden-UI mode still exposes capture and rating to
VoiceOver via custom actions; Dynamic Type up to accessibility XL on every
screen except the canvas overlays, which cap at XXL.

## Library

The library is every frame from every session in one grid, plus collections.
It uses the same dark theme as every other screen.

### Layout
| Width | Arrangement |
|-------|-------------|
| Compact (iPhone) | Tabs: Shoot/Connect · **Library** · Sessions · Settings. The Library tab is a stack: source list → grid; the inspector is a sheet (medium/large detents). |
| Regular (iPad, wide iPhone landscape) | `NavigationSplitView`, balanced: sidebar 320 pt (sources) · content (grid) · detail (inspector, toggled, ~360 pt). The shoot screen is a full-screen cover; a persistent accent "Live · camera" pill at the bottom brings it back from anywhere. |

The fork lives in one place (`RootView` on `horizontalSizeClass`); every child
view is shared.

### Sidebar
Sections in order: Shoot (regular only) · Library (built-ins: All, Picks,
Five stars, Unrated, Today, Rejects) · Pinned · My collections (drag to
reorder, New collection, New smart collection from current filter) · Smart
collections · Sessions · Cameras. Each row: symbol (tinted by the
collection's label colour), name, count in `hud` type. Swipe leading = pin,
trailing = rename / delete (never on built-ins); the same actions in the
context menu.

### Grid and tile anatomy
`LazyVGrid`, 2–6 columns, 2-pt gutters; pinch snaps between levels (one
`rate` haptic per step), the zoom menu names them "N per row". RAW+JPEG pairs
collapse to one tile with an `R+J` badge; "Expand stack" lives in the tile's
context menu. Tile corners: top-left flag (ok) / reject (danger) + label dot;
top-right RAW or R+J badge; bottom-left rating dots; bottom-right look dot.
Not-ready frames dim to 45 % under a download ring; rejects dim to 40 %.
Selection: `Select` button or the context menu enters selection mode; a tile
shows a checkmark circle, selected tiles scale to 0.96 with an accent 2-pt
ring; a drag across tiles range-selects from the first tile touched.

### Filter bar
One scrolling chip row (`hud` type, 32 pt chips inside 44 pt targets):
rating ≥, flag, colour, kind, tags (autocomplete from tag history), date,
session, camera, exported. Active chips use the chip-selected style; a
leading accent chip shows `CaptureFilter.summary` and clears everything.
"Save as smart collection" appears at the end when a filter is active. The
same chips edit a smart collection's rule in the editor with a live count.

### Batch bar
Slides up from the bottom (`arrive`) when the selection is non-empty: "N
selected · Clear", then quick commands (1–5 ★, pick, reject, tag, collect,
export) as 52-pt buttons and a More menu with the rest. Every entry comes
from `Commands.available(in:)`; nothing is hand-listed.

### Command palette and shortcuts
⌘K (iPad keyboard) or the title menu (iPhone) opens a medium sheet with a
search field; results are grouped by command group with symbol and shortcut
hint; Return runs the highlighted (first) result. Every command's shortcut
hint is parsed into a real `.keyboardShortcut` on iPad. The palette owns ⌘K,
so "Add to collection…" has no key binding.

### Undo
Toolbar Undo/Redo carry the editor's titles ("Undo Rate 5★"), ⌘Z / ⇧⌘Z on
iPad, shake on iPhone. A toast "Undid Rate 5★" confirms. Every rating, flag,
label, tag and collection change in the library, loupe, inspector and
filmstrip goes through `ReviewEditor`, so all of them are undoable and the
shoot screen and library never disagree.

### Inspector
Large preview (tap → loupe), facts (session, camera, lens, exposure, size,
captured time, look, EXIF time), review controls, tag editor with recent
tags, collections it belongs to (add/remove), export history, "Reveal in
session".

### What memory restores
Per source (collection, session, camera): filter, sort, columns, stack
pairs, inspector open, last frame scrolled to. Globally: the last source
(Home's "Continue where you left off"), the last export (destination,
options, scope → "Export like last time"), recent tags / collections /
searches, per-camera look + destination + exposure (offered on reconnect as a
one-line banner), session templates (New Session's card row) and the
metadata profile.
