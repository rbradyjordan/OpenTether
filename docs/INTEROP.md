# Interoperability

Tether is the on-set front door; the edit happens elsewhere. Everything a
photographer decides in Tether must travel with the files, in the formats
the rest of the pro toolchain already reads. This is what travels, where,
and how each tool picks it up.

## What travels

| Decision in Tether | Where it goes | Lightroom Classic / CC | Capture One | Photo Mechanic | Bridge |
|---|---|---|---|---|---|
| Star rating 1–5 | `xmp:Rating` | ✓ rating | ✓ rating | ✓ rating | ✓ |
| Reject | `xmp:Rating = -1` | shows as rejected on import | reads as 0 (see below) | ✓ | ✓ |
| Pick | `photomechanic:Tagged = True` + keyword `tether:pick` | keyword only (LR never stores its flag in XMP) | keyword | ✓ Tagged | keyword |
| Colour label | `xmp:Label` (Red/Yellow/Green/Blue/Purple) + `photomechanic:ColorClass` 1–5 | ✓ label | ✓ colour tag | ✓ colour class | ✓ |
| Tags | `dc:subject` + `lr:hierarchicalSubject` (`Root|tag`) | ✓ keywords, hierarchy | ✓ keywords | ✓ keywords | ✓ |
| Creator / copyright | `dc:creator`, `dc:rights`, `xmpRights:Marked` | ✓ IPTC | ✓ | ✓ | ✓ |
| Session name | `photoshop:Headline` + keyword | ✓ | ✓ | ✓ | ✓ |
| Caption template | `dc:description` | ✓ | ✓ | ✓ | ✓ |

Capture One ignores negative ratings; rejected frames also land in the
`Trash` folder of the Capture One session layout, so the decision survives
either way.

## Where it is written

- **Exported JPEG/HEIF**: an XMP APP1 segment embedded after Exif (replacing
  any earlier packet), so the metadata cannot separate from the file.
- **RAW**: a `.xmp` sidecar with the same base name next to the file. Never
  written into the RAW itself.
- **JPEG sidecars** (optional, Photo Mechanic / Capture One habit): on when
  the profile asks.
- **Manifest** (optional): `<session>-manifest.json` and `.csv` with every
  frame's name, exported name, rating, flag, label, tags, collections,
  capture time, camera, exposure, dimensions. The CSV opens in Numbers,
  Excel and Photo Mechanic's ingest; the JSON is for the business platform.

Settings → Metadata & interoperability holds the profile: creator,
copyright (`{year}` is filled in), caption template, hierarchical keyword
root, whether to embed, which sidecars to write, whether to read incoming
XMP.

## Folder layouts and names

Export chooses a `FolderLayout`:

| Layout | Tree | For |
|---|---|---|
| Flat | files only | quick hand-offs |
| By date | `2026/2026-10-16/` | Lightroom import by date |
| By session | `<session>/` | one job, one folder |
| Capture One session | `<session>/Capture · Selects · Output · Trash` (picks → Selects, rejects → Trash, manifests → Output) | drop the folder into C1 as a session |
| By rating | `5 stars/ … /Unrated` | fast delivery of selects |

Names come from a `NamingTemplate` with the tokens pros expect:
`{orig}` `{ext}` `{session}` `{date}` `{time}` `{year}` `{month}` `{day}`
`{seq}` or `{seq:4}` `{camera}` `{rating}` `{label}` `{pick}` `{kind}` `{tag}`
`{client}`. Names are made filesystem-safe and de-duplicated per folder.

## What comes in

Files pushed over FTP or imported from Files bring their metadata with
them: a sidecar `.xmp` next to the file, or the embedded packet in a JPEG,
seeds the rating, flag, label and tags in the library (and the sidecar is
consumed). Lightroom, Capture One and Photo Mechanic output all parse,
including attribute-style XMP.

EXIF is read for the inspector and manifest (make, model, lens, exposure,
ISO, focal length, bias, original time, serial, artist, copyright) straight
from the JPEG or the RAW's TIFF header.

## Transfer paths

- **Photos**: JPEGs with embedded XMP (Photos keeps the packet; Lightroom
  reads it when importing from Photos).
- **Files**: any layout above, with sidecars and manifests. iCloud Drive,
  SMB shares and external SSDs are all Files locations.
- **FTP / FTPS**: same tree on the server; Capture One and Lightroom watch
  folders pick it up.
- **Cloud batch**: a ZIP of the files; the manifest describes them.
- **Share sheet**: hands a rendered JPEG to any app (Lightroom, Capture One
  for iPad, Photoshop Express, Slack).

## Not done, on purpose

No Lightroom catalog (`.lrcat`) writing, no Capture One `.cosessiondb`
writing: both are undocumented databases that break across versions. The
sidecar/embedded route is what both vendors support for third parties.
