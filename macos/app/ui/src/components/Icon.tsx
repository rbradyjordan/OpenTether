import type { CSSProperties, ReactNode } from "react";

// A small stroke icon set keyed by the SF Symbol names the iOS app (and the
// data: collection symbols, template symbols, toast symbols) uses. 24×24 grid.

const P = (d: string) => <path d={d} />;

const ICONS: Record<string, ReactNode> = {
  "camera": <>{P("M3 8.5A2.5 2.5 0 0 1 5.5 6h2l1.5-2h6l1.5 2h2A2.5 2.5 0 0 1 21 8.5v9a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z")}<circle cx="12" cy="13" r="3.6" /></>,
  "camera.aperture": <><circle cx="12" cy="12" r="9" />{P("M14.3 3.3 9.6 11.5M20.6 9.5h-9.4M17.6 19l-4.7-8.1M9.7 20.7l4.7-8.1M3.4 14.5h9.4M6.4 5l4.7 8.1")}</>,
  "camera.filters": <><circle cx="9" cy="9.5" r="5.5" /><circle cx="15" cy="9.5" r="5.5" /><circle cx="12" cy="14.5" r="5.5" /></>,
  "camera.badge.ellipsis": <>{P("M3 8.5A2.5 2.5 0 0 1 5.5 6h2l1.5-2h6l1.5 2h2A2.5 2.5 0 0 1 21 8.5v9a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z")}<circle cx="8.5" cy="13" r=".8" /><circle cx="12" cy="13" r=".8" /><circle cx="15.5" cy="13" r=".8" /></>,
  "cable.connector": <>{P("M9 3v4M15 3v4M7 7h10v5a5 5 0 0 1-10 0zM12 17v4")}</>,
  "wifi": <>{P("M2.5 9a14 14 0 0 1 19 0M5.5 12.3a9.5 9.5 0 0 1 13 0M8.6 15.5a5 5 0 0 1 6.8 0")}<circle cx="12" cy="19" r="1.1" fill="currentColor" /></>,
  "wifi.slash": <>{P("M2.5 9a14 14 0 0 1 19 0M5.5 12.3a9.5 9.5 0 0 1 13 0M8.6 15.5a5 5 0 0 1 6.8 0M4 4l16 16")}</>,
  "arrow.down.doc": <>{P("M6 3h8l4 4v14H6zM14 3v4h4M12 10v7M9 14l3 3 3-3")}</>,
  "doc": <>{P("M6 3h8l4 4v14H6zM14 3v4h4")}</>,
  "doc.text": <>{P("M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 15.5h6M9 9h2")}</>,
  "doc.badge.plus": <>{P("M6 3h8l4 4v6M14 3v4h4M6 3v18h7M18 16v6M15 19h6")}</>,
  "book.pages": <>{P("M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5zM4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5M8 7h8M8 10.5h6")}</>,
  "book": <>{P("M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5zM4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5")}</>,
  "books.vertical": <>{P("M4 4h4v16H4zM10 4h4v16h-4zM15.5 5l3.7-1 3 15.5-3.8 1z")}</>,
  "play": P("M7 4.5v15l12.5-7.5z"),
  "play.fill": <path d="M7 4.5v15l12.5-7.5z" fill="currentColor" />,
  "play.rectangle": <>{P("M3 6h18v12H3zM10 9.5v5l4.3-2.5z")}</>,
  "pause.fill": <><rect x="6" y="4.5" width="4" height="15" rx="1" fill="currentColor" /><rect x="14" y="4.5" width="4" height="15" rx="1" fill="currentColor" /></>,
  "pause.circle": <><circle cx="12" cy="12" r="9" />{P("M10 9v6M14 9v6")}</>,
  "stop.circle": <><circle cx="12" cy="12" r="9" /><rect x="9" y="9" width="6" height="6" rx="1" /></>,
  "plus": P("M12 5v14M5 12h14"),
  "plus.circle.fill": <><circle cx="12" cy="12" r="9" fill="currentColor" /><path d="M12 8v8M8 12h8" stroke="var(--surface-1)" /></>,
  "minus.circle": <><circle cx="12" cy="12" r="9" />{P("M8 12h8")}</>,
  "gearshape": <><circle cx="12" cy="12" r="3.2" />{P("M12 2.8v2.4M12 18.8v2.4M21.2 12h-2.4M5.2 12H2.8M18.5 5.5l-1.7 1.7M7.2 16.8l-1.7 1.7M18.5 18.5l-1.7-1.7M7.2 7.2 5.5 5.5")}<circle cx="12" cy="12" r="6.6" /></>,
  "xmark": P("M6 6l12 12M18 6 6 18"),
  "xmark.circle.fill": <><circle cx="12" cy="12" r="9" fill="currentColor" /><path d="M9 9l6 6M15 9l-6 6" stroke="var(--surface-1)" /></>,
  "xmark.bin": <>{P("M4 7h16M6 7l1 13h10l1-13M9.5 11l5 5M14.5 11l-5 5M9 7V4h6v3")}</>,
  "checkmark": P("M5 12.5l4.5 4.5L19 7.5"),
  "checkmark.circle": <><circle cx="12" cy="12" r="9" />{P("M8 12.3l2.8 2.8L16.5 9.3")}</>,
  "checkmark.circle.fill": <><circle cx="12" cy="12" r="9" fill="currentColor" /><path d="M8 12.3l2.8 2.8L16.5 9.3" stroke="var(--surface-1)" strokeWidth="2" /></>,
  "checkmark.seal": <>{P("M12 2.5l2.3 1.8 2.9-.3.9 2.8 2.5 1.5-.9 2.8.9 2.7-2.5 1.6-.9 2.8-2.9-.3-2.3 1.8-2.3-1.8-2.9.3-.9-2.8L3.8 15l.9-2.7-.9-2.8 2.5-1.5.9-2.8 2.9.3z")}{P("M8.5 12.2l2.4 2.4 4.6-4.8")}</>,
  "chevron.right": P("M9 5l7 7-7 7"),
  "chevron.left": P("M15 5l-7 7 7 7"),
  "chevron.down": P("M5 9l7 7 7-7"),
  "chevron.up": P("M5 15l7-7 7 7"),
  "chevron.up.chevron.down": P("M8 9l4-4 4 4M8 15l4 4 4-4"),
  "star": P("M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8-5.2-2.8-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z"),
  "star.fill": <path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8-5.2-2.8-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z" fill="currentColor" />,
  "star.slash": <>{P("M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8-5.2-2.8-5.2 2.8 1-5.8-4.3-4.1 5.9-.8zM4 4l16 16")}</>,
  "flag": P("M5 21V4M5 4h11l-2 4 2 4H5"),
  "flag.fill": <><path d="M5 4h11l-2 4 2 4H5z" fill="currentColor" />{P("M5 21V4")}</>,
  "flag.slash": P("M5 21V4M5 4h11l-2 4 2 4H5M3 3l18 18"),
  "xmark.circle": <><circle cx="12" cy="12" r="9" />{P("M9 9l6 6M15 9l-6 6")}</>,
  "circle": <circle cx="12" cy="12" r="8" />,
  "circle.fill": <circle cx="12" cy="12" r="8" fill="currentColor" />,
  "circle.dashed": <circle cx="12" cy="12" r="8" strokeDasharray="3 3" />,
  "circle.inset.filled": <><circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="5.5" fill="currentColor" /></>,
  "circle.lefthalf.filled": <><circle cx="12" cy="12" r="8" /><path d="M12 4a8 8 0 0 0 0 16z" fill="currentColor" /></>,
  "number": P("M9.5 4 7.5 20M16.5 4l-2 16M4.5 9h15M4 15h15"),
  "tag": <>{P("M3.5 12.5V4h8.5l8.5 8.5-8.5 8.5z")}<circle cx="8" cy="8.5" r="1.3" /></>,
  "tag.fill": <><path d="M3.5 12.5V4h8.5l8.5 8.5-8.5 8.5z" fill="currentColor" /></>,
  "rectangle.stack": <>{P("M4 9h16v11H4zM6 6h12M8 3h8")}</>,
  "rectangle.stack.badge.plus": <>{P("M4 9h11M4 9v11h9M6 6h12M8 3h8M18 13v8M14 17h8")}</>,
  "rectangle.stack.badge.minus": <>{P("M4 9h16v5M4 9v11h9M6 6h12M8 3h8M15 18h7")}</>,
  "rectangle.stack.badge.person.crop": <>{P("M4 9h16v11H4zM6 6h12M8 3h8")}<circle cx="12" cy="13" r="2" />{P("M8.5 18.5a4 4 0 0 1 7 0")}</>,
  "plus.rectangle.on.rectangle": <>{P("M8 8h12v12H8zM4 16V4h12M14 11v6M11 14h6")}</>,
  "sparkles.rectangle.stack": <>{P("M4 9h16v11H4zM6 6h12M8 3h8M12 11.5l1 2.5 2.5 1-2.5 1-1 2.5-1-2.5-2.5-1 2.5-1z")}</>,
  "sparkles": <>{P("M10 3.5l1.6 4.4L16 9.5l-4.4 1.6L10 15.5l-1.6-4.4L4 9.5l4.4-1.6zM18 13l.9 2.1 2.1.9-2.1.9L18 19l-.9-2.1-2.1-.9 2.1-.9z")}</>,
  "sun.max": <><circle cx="12" cy="12" r="4" />{P("M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4")}</>,
  "moon": P("M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z"),
  "calendar": <>{P("M4 6h16v14H4zM4 10h16M8 3.5v4M16 3.5v4")}</>,
  "photo": <>{P("M3.5 5h17v14h-17zM3.5 16l5-5 4 4 3-3 5 5")}<circle cx="15.5" cy="9" r="1.5" /></>,
  "photo.on.rectangle": <>{P("M7 7h14v12H7zM7 16l4-4 3.5 3.5L17 13l4 4M3 15V3h14")}</>,
  "photo.on.rectangle.angled": <>{P("M7 7h14v12H7zM7 16l4-4 3.5 3.5L17 13l4 4M3 15V3h14")}</>,
  "photo.badge.plus": <>{P("M3.5 5h11M3.5 5v14h10M3.5 16l5-5 4 4M18 12v8M14 16h8")}</>,
  "square.and.arrow.up": <>{P("M12 3v12M7.5 7.5 12 3l4.5 4.5M7 11H5v10h14V11h-2")}</>,
  "square.and.arrow.down": <>{P("M12 3v12M7.5 10.5 12 15l4.5-4.5M7 9H5v12h14V9h-2")}</>,
  "square.and.arrow.down.on.square": <>{P("M12 3v9M8.5 8.5 12 12l3.5-3.5M8 6H5v12h14V6h-3M8 21h11")}</>,
  "arrow.up.doc": <>{P("M6 3h8l4 4v14H6zM14 3v4h4M12 17v-7M9 13l3-3 3 3")}</>,
  "arrow.uturn.up": P("M9 20V9a4 4 0 0 1 4-4h0a4 4 0 0 1 4 4v11M5.5 12.5 9 9l3.5 3.5"),
  "arrow.uturn.backward": P("M9 14 4 9l5-5M4 9h10.5a5.5 5.5 0 0 1 0 11H11"),
  "arrow.uturn.forward": P("M15 14l5-5-5-5M20 9H9.5a5.5 5.5 0 0 0 0 11H13"),
  "arrow.counterclockwise": P("M4 4.5v5h5M4.5 9.5A8 8 0 1 1 6 16.5"),
  "arrow.clockwise": P("M20 4.5v5h-5M19.5 9.5A8 8 0 1 0 18 16.5"),
  "arrow.triangle.2.circlepath": P("M4 12a8 8 0 0 1 13.6-5.7L20 8.5M20 4v4.5h-4.5M20 12a8 8 0 0 1-13.6 5.7L4 15.5M4 20v-4.5h4.5"),
  "arrow.right.to.line": P("M3 12h13M11 7l5 5-5 5M20 4v16"),
  "arrow.left.arrow.right": P("M4 8h15M15 4l4 4-4 4M20 16H5M9 12l-4 4 4 4"),
  "arrow.up.arrow.down": P("M7 20V4M3.5 7.5 7 4l3.5 3.5M17 4v16M13.5 16.5 17 20l3.5-3.5"),
  "arrow.down": P("M12 4v16M5.5 13.5 12 20l6.5-6.5"),
  "arrow.down.circle": <><circle cx="12" cy="12" r="9" />{P("M12 7.5v9M8 12.5l4 4 4-4")}</>,
  "arrow.up.forward.app": <>{P("M10 4H5v15h15v-5M13 4h7v7M20 4l-9 9")}</>,
  "folder": P("M3 6.5V19h18V8.5h-9L10 5.5H3z"),
  "folder.badge.plus": <>{P("M3 6.5V19h10M3 6.5V5.5h7l2 3h9v4.5M18 14v8M14 18h8")}</>,
  "folder.badge.gearshape": <>{P("M3 6.5V19h9M3 6.5V5.5h7l2 3h9v4")}<circle cx="18" cy="17" r="2.2" />{P("M18 12.8v1.5M18 19.7v1.5M22.2 17h-1.5M15.3 17h-1.5")}</>,
  "server.rack": <>{P("M4 4h16v6H4zM4 14h16v6H4z")}<circle cx="7.5" cy="7" r=".9" fill="currentColor" /><circle cx="7.5" cy="17" r=".9" fill="currentColor" /></>,
  "info.circle": <><circle cx="12" cy="12" r="9" />{P("M12 11v6")}<circle cx="12" cy="7.8" r="1" fill="currentColor" /></>,
  "sidebar.right": <>{P("M3.5 5h17v14h-17zM15 5v14")}</>,
  "sidebar.left": <>{P("M3.5 5h17v14h-17zM9 5v14")}</>,
  "square.grid.3x3": <>{P("M4 4h4.7v4.7H4zM9.7 4h4.6v4.7H9.7zM15.3 4H20v4.7h-4.7zM4 9.7h4.7v4.6H4zM9.7 9.7h4.6v4.6H9.7zM15.3 9.7H20v4.6h-4.7zM4 15.3h4.7V20H4zM9.7 15.3h4.6V20H9.7zM15.3 15.3H20V20h-4.7z")}</>,
  "square.2.layers.3d": <>{P("M12 3 3 8l9 5 9-5zM3 12.5l9 5 9-5M3 17l9 5 9-5")}</>,
  "trash": <>{P("M4 7h16M6.5 7l1 13h9l1-13M9.5 7V4h5v3M10 11v6M14 11v6")}</>,
  "pencil": P("M4 20l1-4.5L16 4.5l3.5 3.5L8.5 19zM14 7l3.5 3.5"),
  "pin": P("M15 3l6 6-3.5 1.5-4 4 .5 4.5-2 1-3.5-3.5L4 21l-.5-.5 4.5-4.5L4.5 12.5l1-2L10 11l4-4z"),
  "pin.fill": <path d="M15 3l6 6-3.5 1.5-4 4 .5 4.5-2 1-3.5-3.5L4 21l-.5-.5 4.5-4.5L4.5 12.5l1-2L10 11l4-4z" fill="currentColor" />,
  "pin.slash": P("M15 3l6 6-3.5 1.5-4 4 .5 4.5-2 1-3.5-3.5L4 21M3 3l18 18"),
  "line.3.horizontal.decrease.circle": <><circle cx="12" cy="12" r="9" />{P("M7 9h10M9 12.5h6M11 16h2")}</>,
  "magnifyingglass": <><circle cx="10.5" cy="10.5" r="6.5" />{P("M15.5 15.5 21 21")}</>,
  "command": P("M9 9V6.5A2.5 2.5 0 1 0 6.5 9H9zm0 0h6M9 9v6m6-6V6.5A2.5 2.5 0 1 1 17.5 9H15zm0 0v6m0 0h-6m6 0v2.5a2.5 2.5 0 1 0 2.5-2.5H15zm-6 0v2.5A2.5 2.5 0 1 1 6.5 15H9z"),
  "eye": <>{P("M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z")}<circle cx="12" cy="12" r="3" /></>,
  "video": <>{P("M3 7h12v10H3zM15 10.5l6-3.5v10l-6-3.5")}</>,
  "video.fill": <><path d="M3 7h12v10H3zM15 10.5l6-3.5v10l-6-3.5z" fill="currentColor" /></>,
  "battery.75percent": <><rect x="2.5" y="7" width="17" height="10" rx="2.5" /><rect x="4.5" y="9" width="10" height="6" rx="1" fill="currentColor" stroke="none" />{P("M21.5 10.5v3")}</>,
  "bolt.slash": P("M13 3 5 13.5h6L10 21l3.5-4.5M14.5 11H19l-2.5 3.3M3 3l18 18"),
  "bolt.slash.fill": P("M13 3 5 13.5h6L10 21l3.5-4.5M14.5 11H19l-2.5 3.3M3 3l18 18"),
  "bolt": P("M13 3 5 13.5h6L10 21l8-10.5h-6z"),
  "stethoscope": <>{P("M6 3v5a4.5 4.5 0 0 0 9 0V3M10.5 12.5V15a4.5 4.5 0 0 0 9 0v-2")}<circle cx="19.5" cy="11" r="2" /></>,
  "lock.shield": <>{P("M12 3l7.5 3v6c0 4.5-3.3 7.8-7.5 9-4.2-1.2-7.5-4.5-7.5-9V6z")}<rect x="9" y="11" width="6" height="5" rx="1" />{P("M10 11V9.5a2 2 0 0 1 4 0V11")}</>,
  "lock.shield.fill": <>{P("M12 3l7.5 3v6c0 4.5-3.3 7.8-7.5 9-4.2-1.2-7.5-4.5-7.5-9V6z")}<rect x="9" y="11" width="6" height="5" rx="1" fill="currentColor" />{P("M10 11V9.5a2 2 0 0 1 4 0V11")}</>,
  "hand.raised": P("M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 10.5V4a1.5 1.5 0 0 1 3 0v6.5M14 10.5V5.5a1.5 1.5 0 0 1 3 0V13M17 9.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-2.7L4.2 14a1.6 1.6 0 0 1 2.6-1.8L8 14"),
  "hand.raised.fill": P("M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 10.5V4a1.5 1.5 0 0 1 3 0v6.5M14 10.5V5.5a1.5 1.5 0 0 1 3 0V13M17 9.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-2.7L4.2 14a1.6 1.6 0 0 1 2.6-1.8L8 14"),
  "key": <><circle cx="8" cy="14" r="4" />{P("M11 11.5 20 3M16.5 6.5l2.5 2.5M14.5 8.5 16 10")}</>,
  "person.badge.key": <><circle cx="10" cy="8" r="3.5" />{P("M3.5 20a6.5 6.5 0 0 1 10-5.5")}<circle cx="17" cy="16" r="2" />{P("M19 16h3M21 16v2")}</>,
  "person.crop.rectangle": <>{P("M3 5h18v14H3z")}<circle cx="12" cy="10.5" r="2.5" />{P("M7.5 19a4.5 4.5 0 0 1 9 0")}</>,
  "person.text.rectangle": <>{P("M3 5h18v14H3z")}<circle cx="8.5" cy="10.5" r="2" />{P("M5 16a3.5 3.5 0 0 1 7 0M14 10h4.5M14 13.5h3")}</>,
  "rectangle.inset.filled": <>{P("M3 5h18v14H3z")}<rect x="6" y="8" width="12" height="8" fill="currentColor" stroke="none" /></>,
  "wand.and.stars": <>{P("M4 20 15 9M13.5 7.5l3 3M17.5 3l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6zM6.5 4l.5 1 1 .5-1 .5-.5 1-.5-1-1-.5 1-.5zM19.5 12l.5 1 1 .5-1 .5-.5 1-.5-1-1-.5 1-.5z")}</>,
  "rectangle.split.2x1": <>{P("M3 5h18v14H3zM12 5v14")}</>,
  "ellipsis": <><circle cx="6" cy="12" r="1.3" fill="currentColor" /><circle cx="12" cy="12" r="1.3" fill="currentColor" /><circle cx="18" cy="12" r="1.3" fill="currentColor" /></>,
  "ellipsis.circle": <><circle cx="12" cy="12" r="9" /><circle cx="8" cy="12" r="1" fill="currentColor" /><circle cx="12" cy="12" r="1" fill="currentColor" /><circle cx="16" cy="12" r="1" fill="currentColor" /></>,
  "list.bullet": <>{P("M9 6h11M9 12h11M9 18h11")}<circle cx="4.5" cy="6" r="1" fill="currentColor" /><circle cx="4.5" cy="12" r="1" fill="currentColor" /><circle cx="4.5" cy="18" r="1" fill="currentColor" /></>,
  "list.bullet.rectangle": <>{P("M3 4h18v16H3zM10 9h7M10 12h7M10 15h7")}<circle cx="7" cy="9" r=".8" fill="currentColor" /><circle cx="7" cy="12" r=".8" fill="currentColor" /><circle cx="7" cy="15" r=".8" fill="currentColor" /></>,
  "clock": <><circle cx="12" cy="12" r="9" />{P("M12 7v5l3 2")}</>,
  "clock.arrow.circlepath": <>{P("M4 4.5v5h5M4.5 9.5A8 8 0 1 1 6 16.5M12 8v4.5l3 1.8")}</>,
  "laptopcomputer": <>{P("M5 5h14v10H5zM2.5 19h19")}</>,
  "antenna.radiowaves.left.and.right": <>{P("M12 11v10M7.5 7.5a6.4 6.4 0 0 0 0 9M16.5 7.5a6.4 6.4 0 0 1 0 9M4.5 4.5a10.6 10.6 0 0 0 0 15M19.5 4.5a10.6 10.6 0 0 1 0 15")}<circle cx="12" cy="12" r="1.5" fill="currentColor" /></>,
  "dot.radiowaves.left.and.right": <>{P("M7.5 7.5a6.4 6.4 0 0 0 0 9M16.5 7.5a6.4 6.4 0 0 1 0 9M4.5 4.5a10.6 10.6 0 0 0 0 15M19.5 4.5a10.6 10.6 0 0 1 0 15")}<circle cx="12" cy="12" r="1.8" fill="currentColor" /></>,
  "lightbulb": <>{P("M9 18h6M10 21h4M8.5 14.5A6 6 0 1 1 15.5 14.5c-.9.7-1.5 1.6-1.5 2.5v1h-4v-1c0-.9-.6-1.8-1.5-2.5z")}</>,
  "network": <><circle cx="12" cy="12" r="9" />{P("M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18")}</>,
  "tray.and.arrow.down": <>{P("M3 14h5l1.5 3h5l1.5-3h5v6H3zM12 3v9M8.5 8.5 12 12l3.5-3.5")}</>,
  "internaldrive": <>{P("M3 13l2.5-8h13L21 13v6H3zM3 13h18")}<circle cx="17" cy="16" r=".9" fill="currentColor" /></>,
  "heart": P("M12 20s-7.5-4.6-9-9.5C2 6.7 4.6 4 7.5 4c1.9 0 3.5 1 4.5 2.5C13 5 14.6 4 16.5 4 19.4 4 22 6.7 21 10.5 19.5 15.4 12 20 12 20z"),
  "leaf": P("M5 19C5 10 10 5 20 4c-1 10-6 15-15 15zM5 19l8-8"),
  "bolt.fill": <path d="M13 3 5 13.5h6L10 21l8-10.5h-6z" fill="currentColor" />,
  "paintpalette": <>{P("M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-1-1.5-1-2.5S14 15 15 15h2a4 4 0 0 0 4-4c0-4.4-4-8-9-8z")}<circle cx="7.5" cy="11" r="1.2" /><circle cx="10" cy="7" r="1.2" /><circle cx="15" cy="7.5" r="1.2" /></>,
  "building.2": <>{P("M3 21h18M5 21V5h9v16M14 9h5v12M8 8h3M8 11.5h3M8 15h3")}</>,
  "airplane": P("M10.5 21l1.5-1.5V14l8 3v-2l-8-5V4.5a1.5 1.5 0 0 0-3 0V10l-8 5v2l8-3v5.5L10.5 21z"),
  "keyboard": <>{P("M2.5 6h19v12h-19zM6 10h1M9 10h1M12 10h1M15 10h1M18 10h1M7 14h10")}</>,
  "flask": P("M9 3h6M10 3v6L4.5 19a1.5 1.5 0 0 0 1.3 2h12.4a1.5 1.5 0 0 0 1.3-2L14 9V3M7 15h10"),
  "exclamationmark.triangle": <>{P("M12 3.5 2.5 20h19zM12 10v5")}<circle cx="12" cy="17.5" r="1" fill="currentColor" /></>,
  "exclamationmark.triangle.fill": <><path d="M12 3.5 2.5 20h19z" fill="currentColor" /><path d="M12 10v5" stroke="var(--surface-1)" /><circle cx="12" cy="17.5" r="1" fill="var(--surface-1)" stroke="none" /></>,
  "checkmark.seal.fill": <><path d="M12 2.5l2.3 1.8 2.9-.3.9 2.8 2.5 1.5-.9 2.8.9 2.7-2.5 1.6-.9 2.8-2.9-.3-2.3 1.8-2.3-1.8-2.9.3-.9-2.8L3.8 15l.9-2.7-.9-2.8 2.5-1.5.9-2.8 2.9.3z" fill="currentColor" /><path d="M8.5 12.2l2.4 2.4 4.6-4.8" stroke="var(--surface-1)" /></>,
  "rectangle.3.group": <>{P("M3 4h18v7H3zM3 14h8v6H3zM13 14h8v6h-8z")}</>,
  "square.dashed": <rect x="4" y="4" width="16" height="16" rx="2" strokeDasharray="3 3" />,
  "link": P("M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"),
  "slider.horizontal.3": <>{P("M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1")}<circle cx="15" cy="6" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="17" cy="18" r="2" /></>,
  "iphone": <>{P("M7 2.5h10v19H7zM11 18.5h2")}</>,
  "desktopcomputer": <>{P("M3 4h18v12H3zM9 20h6M12 16v4")}</>,
  "battery.100.bolt": <><rect x="2.5" y="7" width="17" height="10" rx="2.5" />{P("M21.5 10.5v3M11.5 8.5l-2.5 4h3l-1 3")}</>,
  "eye.slash": <>{P("M2.5 12S6 5.5 12 5.5c1.6 0 3 .4 4.2 1M21.5 12s-1.2 2.3-3.6 4.2M9.5 18.1c.8.3 1.6.4 2.5.4M4 4l16 16")}</>,
  "minus": P("M5 12h14"),
  "questionmark.folder": <>{P("M3 6.5V19h18V8.5h-9L10 5.5H3zM10.5 11.5a1.8 1.8 0 1 1 2.3 1.7c-.5.2-.8.6-.8 1.1v.4")}<circle cx="12" cy="17" r=".8" fill="currentColor" /></>,
  "rectangle.stack.fill": <><path d="M4 9h16v11H4z" fill="currentColor" />{P("M6 6h12M8 3h8")}</>,
};

const FALLBACK = <><rect x="4" y="4" width="16" height="16" rx="4" /><circle cx="12" cy="12" r="2" fill="currentColor" /></>;

export interface IconProps {
  name: string;
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
  title?: string;
}

export function Icon({ name, size = 16, strokeWidth = 1.8, className, style, title }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={{ flex: "none", ...style }}
      aria-hidden={title ? undefined : true}
      role={title ? "img" : undefined}
    >
      {title ? <title>{title}</title> : null}
      {ICONS[name] ?? FALLBACK}
    </svg>
  );
}

export const knownIcon = (name: string) => name in ICONS;
