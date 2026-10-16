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
them: a sidecar `.xmp` next to the file (`IMG.xmp` or `IMG.CR3.xmp`), or the
embedded packet in a JPEG, seeds the rating, flag, label and tags in the
library. Over FTP a sidecar may arrive before or after its photo: it is
applied to the frame (and its RAW/JPEG twin) either way, never imported as a
frame. Files imported from the Files app are copied; the source folder is
never changed. Lightroom, Capture One and Photo Mechanic output all parse,
including attribute-style XMP.

EXIF is read for the inspector and manifest (make, model, lens, exposure,
ISO, focal length, bias, original time, serial, artist, copyright) straight
from the JPEG or the RAW's TIFF header.

## Transfer paths

- **Photos**: JPEGs with embedded XMP (Photos keeps the packet; Lightroom
  reads it when importing from Photos).
- **Files**: any layout above, with sidecars and manifests, into "On My
  iPhone › Open Tether" or a **saved folder** picked anywhere in Files
  (iCloud Drive, a server under Connect to Server, a USB-C drive). Saved
  folders are security-scoped bookmarks; writes are coordinated and atomic
  (a hidden temporary name, then moved into place) and replace earlier
  copies instead of adding "-1" duplicates.
- **Hot folder**: a session can copy every frame into a saved folder the
  moment it lands (originals, camera names, sidecar first). Rating, picking
  or labelling on the phone rewrites the sidecar there.
- **Capture One session**: pick the session's root folder (the one holding
  the `.cosessiondb`); exports and the hot folder write straight into its
  Capture / Selects / Trash folders (manifests to Output), creating any that
  are missing.
- **Lightroom Classic Auto Import**: mark a saved folder as an Auto Import
  folder; files go in flat, each sidecar written before its photo.
- **FTP / FTPS**: same tree on the server; Capture One and Lightroom watch
  folders pick it up.
- **Share sheet**: hands a rendered JPEG to any app (Lightroom, Capture One
  for iPad, Photoshop Express, Slack).

## RAW

RAW originals are never altered. RAW+JPEG twins keep one base name on
export (whatever the naming pattern: the pair's first sequence number is
used) and get one sidecar, the RAW's, so Lightroom and Capture One re-stack
them. RAW can instead be exported developed (Core Image `CIRAWFilter`,
as-shot white balance) to JPEG (with embedded XMP), HEIF or 16-bit TIFF,
with the look and resize applied.

## Reading catalogs back

"Sync ratings from a catalog…" (Library) or opening a catalog from Files
reads a **Lightroom Classic** `.lrcat` (`Adobe_images` rating / pick /
colour label, `AgLibraryFile` names, keywords) or a **Capture One** catalog
or session database (rating and colour tag; the schema is probed, so this is
marked experimental). The catalog and its `-wal` journal are copied to a
private folder and read from there: the original is never opened, locked or
written, and edits the desktop app has not checkpointed yet are included.
Frames match by camera file name or by any name they were exported under.
The sheet shows what would change; applying it is one undoable edit per
kind. Capture One's orange and pink tags have no equivalent and are left
alone.

## Not done, on purpose

No writing into a Lightroom catalog (`.lrcat`) or a Capture One catalog or
`.cosessiondb`: both are undocumented databases the desktop app keeps open
and migrates between versions. The sidecar / embedded / watched-folder route
is what both vendors support for third parties, and catalogs are only read.
