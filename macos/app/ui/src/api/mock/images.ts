// Photo-like frames drawn with canvas gradients, so the mock library and the
// demo camera have something worth rating. Deterministic per seed.

export type Scene = "landscape" | "portrait" | "product" | "city" | "sea";

export interface SceneSpec {
  scene: Scene;
  seed: number;
  /** 0…1: time of day / variation within a session. */
  t: number;
  /** Tall frame (2:3) instead of 3:2. */
  tall: boolean;
  /** Exposure offset in stops; brightens or darkens the frame. */
  ev: number;
}

export interface LookRecipe {
  warmth?: number;
  tint?: number;
  contrast?: number;
  saturation?: number;
  fade?: number;
  /** Split toning: shadows toward teal, highlights toward orange. */
  split?: number;
}

export function rng(seed: number): () => number {
  let a = seed >>> 0 || 1;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const hsl = (h: number, s: number, l: number, a = 1) => `hsla(${Math.round(h)}, ${Math.round(s * 100)}%, ${Math.round(l * 100)}%, ${a})`;

function sky(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, horizon: number) {
  const g = ctx.createLinearGradient(0, 0, 0, h * horizon);
  g.addColorStop(0, hsl(215 - 20 * t, 0.55, 0.62 - 0.35 * t));
  g.addColorStop(0.65, hsl(205 - 170 * t, 0.45 + 0.2 * t, 0.72 - 0.15 * t));
  g.addColorStop(1, hsl(32 - 12 * t, 0.55 + 0.35 * t, 0.78 - 0.1 * t));
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, w, h);
}

function sun(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, t: number) {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r * 4);
  g.addColorStop(0, hsl(42 - 20 * t, 1, 0.92, 0.95));
  g.addColorStop(0.18, hsl(38 - 20 * t, 1, 0.75, 0.6));
  g.addColorStop(1, hsl(30, 1, 0.6, 0));
  ctx.fillStyle = g;
  ctx.fillRect(x - r * 4, y - r * 4, r * 8, r * 8);
  ctx.fillStyle = hsl(45 - 15 * t, 1, 0.94);
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fill();
}

function landscape(ctx: CanvasRenderingContext2D, w: number, h: number, s: SceneSpec, r: () => number) {
  sky(ctx, w, h, s.t, 0.72);
  sun(ctx, w * (0.25 + 0.5 * s.t + (r() - 0.5) * 0.1), h * (0.22 + 0.28 * s.t), Math.min(w, h) * 0.05, s.t);
  for (let layer = 0; layer < 4; layer++) {
    const base = h * (0.5 + 0.11 * layer);
    const light = Math.max(0.06, 0.48 - 0.11 * layer - 0.18 * s.t);
    ctx.fillStyle = hsl(150 - 25 * layer + 60 * s.t + r() * 10, 0.25 + 0.05 * layer, light);
    ctx.beginPath();
    ctx.moveTo(0, h);
    const phase = r() * 6 + s.seed;
    for (let x = 0; x <= w + 20; x += w / 60) {
      const k = x / w;
      const y = base + Math.sin(k * Math.PI * (2 + layer) + phase) * h * 0.05 + Math.sin(k * Math.PI * 9 + layer + phase) * h * 0.012;
      ctx.lineTo(x, y);
    }
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fill();
  }
  // Mist on the far ridge.
  const mist = ctx.createLinearGradient(0, h * 0.45, 0, h * 0.7);
  mist.addColorStop(0, "rgba(255,255,255,0)");
  mist.addColorStop(0.5, `rgba(255,240,225,${0.14 + 0.1 * (1 - s.t)})`);
  mist.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = mist;
  ctx.fillRect(0, h * 0.45, w, h * 0.25);
}

function sea(ctx: CanvasRenderingContext2D, w: number, h: number, s: SceneSpec, r: () => number) {
  const horizon = 0.52 + (r() - 0.5) * 0.08;
  sky(ctx, w, h, s.t, horizon);
  const sx = w * (0.3 + 0.4 * r());
  sun(ctx, sx, h * (horizon - 0.08 - 0.2 * (1 - s.t)), Math.min(w, h) * 0.045, s.t);
  const water = ctx.createLinearGradient(0, h * horizon, 0, h);
  water.addColorStop(0, hsl(205 - 150 * s.t, 0.4, 0.5 - 0.2 * s.t));
  water.addColorStop(1, hsl(210, 0.5, 0.18));
  ctx.fillStyle = water;
  ctx.fillRect(0, h * horizon, w, h * (1 - horizon));
  // Glitter path under the sun.
  for (let i = 0; i < 90; i++) {
    const y = h * horizon + (h * 0.45 * i) / 90;
    const spread = 6 + (i / 90) * w * 0.12;
    ctx.fillStyle = hsl(40 - 10 * s.t, 1, 0.85, 0.5 * (1 - i / 110) * r());
    ctx.fillRect(sx - spread * r(), y, spread * 2 * r(), Math.max(1, h * 0.003));
  }
  // Sand.
  ctx.fillStyle = hsl(35, 0.35, 0.55 - 0.3 * s.t);
  ctx.beginPath();
  ctx.moveTo(0, h);
  ctx.lineTo(0, h * 0.86);
  ctx.quadraticCurveTo(w * 0.4, h * (0.8 + r() * 0.05), w, h * 0.9);
  ctx.lineTo(w, h);
  ctx.fill();
}

function portrait(ctx: CanvasRenderingContext2D, w: number, h: number, s: SceneSpec, r: () => number) {
  const hue = [210, 30, 260, 160, 0][Math.floor(r() * 5)];
  const bg = ctx.createRadialGradient(w * 0.5, h * 0.4, 0, w * 0.5, h * 0.5, Math.max(w, h) * 0.75);
  bg.addColorStop(0, hsl(hue, 0.18, 0.55 - 0.15 * s.t));
  bg.addColorStop(1, hsl(hue, 0.2, 0.14));
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, w, h);
  const cx = w * (0.5 + (r() - 0.5) * 0.18);
  const unit = Math.min(w, h * 0.9);
  const skin = [hsl(25, 0.45, 0.72), hsl(28, 0.4, 0.58), hsl(24, 0.38, 0.42), hsl(20, 0.35, 0.3)][Math.floor(r() * 4)];
  const cloth = hsl(r() * 360, 0.25 + r() * 0.3, 0.18 + r() * 0.25);
  // Shoulders.
  ctx.fillStyle = cloth;
  ctx.beginPath();
  ctx.moveTo(cx - unit * 0.48, h);
  ctx.bezierCurveTo(cx - unit * 0.46, h * 0.74, cx - unit * 0.2, h * 0.7, cx, h * 0.69);
  ctx.bezierCurveTo(cx + unit * 0.2, h * 0.7, cx + unit * 0.46, h * 0.74, cx + unit * 0.48, h);
  ctx.fill();
  // Neck.
  ctx.fillStyle = skin;
  ctx.fillRect(cx - unit * 0.06, h * 0.52, unit * 0.12, h * 0.19);
  // Head.
  ctx.beginPath();
  ctx.ellipse(cx, h * 0.42, unit * 0.13, unit * 0.17, 0, 0, Math.PI * 2);
  ctx.fill();
  // Hair.
  ctx.fillStyle = hsl(25, 0.35, 0.08 + r() * 0.3);
  ctx.beginPath();
  ctx.ellipse(cx, h * 0.36, unit * 0.145, unit * 0.13, 0, Math.PI, Math.PI * 2);
  ctx.fill();
  if (r() > 0.5) {
    ctx.beginPath();
    ctx.ellipse(cx - unit * 0.11, h * 0.47, unit * 0.05, unit * 0.15, 0.1, 0, Math.PI * 2);
    ctx.ellipse(cx + unit * 0.11, h * 0.47, unit * 0.05, unit * 0.15, -0.1, 0, Math.PI * 2);
    ctx.fill();
  }
  // Key light from the side.
  const key = ctx.createLinearGradient(cx - unit * 0.3, 0, cx + unit * 0.3, 0);
  key.addColorStop(0, "rgba(255,245,230,0.22)");
  key.addColorStop(0.55, "rgba(255,245,230,0)");
  key.addColorStop(1, "rgba(0,0,0,0.25)");
  ctx.fillStyle = key;
  ctx.fillRect(0, 0, w, h);
}

function product(ctx: CanvasRenderingContext2D, w: number, h: number, _s: SceneSpec, r: () => number) {
  const hue = r() * 360;
  const sweep = ctx.createLinearGradient(0, 0, 0, h);
  sweep.addColorStop(0, hsl(hue, 0.12, 0.82));
  sweep.addColorStop(0.62, hsl(hue, 0.15, 0.7));
  sweep.addColorStop(1, hsl(hue, 0.18, 0.58));
  ctx.fillStyle = sweep;
  ctx.fillRect(0, 0, w, h);
  const cx = w * (0.5 + (r() - 0.5) * 0.2);
  const base = h * 0.78;
  const unit = Math.min(w, h);
  // Soft shadow.
  const sh = ctx.createRadialGradient(cx + unit * 0.05, base, 0, cx + unit * 0.05, base, unit * 0.25);
  sh.addColorStop(0, "rgba(0,0,0,0.35)");
  sh.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = sh;
  ctx.save();
  ctx.scale(1, 0.25);
  ctx.beginPath();
  ctx.arc(cx + unit * 0.05, base / 0.25, unit * 0.25, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
  // Vase.
  const vh = unit * (0.42 + r() * 0.15);
  const vw = unit * (0.12 + r() * 0.06);
  const body = ctx.createLinearGradient(cx - vw, 0, cx + vw, 0);
  const vhue = (hue + 180 + r() * 60) % 360;
  body.addColorStop(0, hsl(vhue, 0.35, 0.25));
  body.addColorStop(0.35, hsl(vhue, 0.4, 0.55));
  body.addColorStop(0.45, hsl(vhue, 0.3, 0.8));
  body.addColorStop(1, hsl(vhue, 0.4, 0.2));
  ctx.fillStyle = body;
  ctx.beginPath();
  ctx.moveTo(cx - vw * 0.45, base - vh);
  ctx.bezierCurveTo(cx - vw * 0.4, base - vh * 0.7, cx - vw * 1.35, base - vh * 0.45, cx - vw * 0.8, base);
  ctx.lineTo(cx + vw * 0.8, base);
  ctx.bezierCurveTo(cx + vw * 1.35, base - vh * 0.45, cx + vw * 0.4, base - vh * 0.7, cx + vw * 0.45, base - vh);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = hsl(vhue, 0.3, 0.15);
  ctx.beginPath();
  ctx.ellipse(cx, base - vh, vw * 0.45, vw * 0.1, 0, 0, Math.PI * 2);
  ctx.fill();
  // A second, smaller piece.
  if (r() > 0.4) {
    const bx = cx + vw * 2.2 * (r() > 0.5 ? 1 : -1);
    const bh = vh * 0.45;
    const g2 = ctx.createLinearGradient(bx - vw * 0.6, 0, bx + vw * 0.6, 0);
    g2.addColorStop(0, hsl(hue + 40, 0.2, 0.35));
    g2.addColorStop(0.4, hsl(hue + 40, 0.25, 0.75));
    g2.addColorStop(1, hsl(hue + 40, 0.2, 0.3));
    ctx.fillStyle = g2;
    ctx.beginPath();
    ctx.ellipse(bx, base - bh * 0.5, vw * 0.65, bh * 0.5, 0, 0, Math.PI * 2);
    ctx.fill();
  }
}

function city(ctx: CanvasRenderingContext2D, w: number, h: number, s: SceneSpec, r: () => number) {
  const g = ctx.createLinearGradient(0, 0, 0, h * 0.75);
  g.addColorStop(0, hsl(230, 0.45, 0.12 + 0.1 * (1 - s.t)));
  g.addColorStop(0.7, hsl(270 - 40 * s.t, 0.35, 0.3));
  g.addColorStop(1, hsl(20, 0.7, 0.55 - 0.15 * s.t));
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, w, h);
  let x = -10;
  while (x < w) {
    const bw = w * (0.04 + r() * 0.08);
    const bh = h * (0.18 + r() * 0.5);
    const top = h * 0.82 - bh;
    ctx.fillStyle = hsl(230, 0.2, 0.08 + r() * 0.08);
    ctx.fillRect(x, top, bw, bh + h);
    const cols = Math.max(2, Math.floor(bw / (w * 0.012)));
    const rows = Math.floor(bh / (h * 0.025));
    for (let cy = 0; cy < rows; cy++) {
      for (let cx = 0; cx < cols; cx++) {
        if (r() < 0.45 + 0.3 * s.t) {
          ctx.fillStyle = hsl(40 + r() * 20, 0.9, 0.6 + r() * 0.25, 0.9);
          ctx.fillRect(x + (cx + 0.25) * (bw / cols), top + (cy + 0.3) * (bh / rows), (bw / cols) * 0.5, (bh / rows) * 0.45);
        }
      }
    }
    x += bw + w * 0.004;
  }
  // Water reflection.
  const wg = ctx.createLinearGradient(0, h * 0.82, 0, h);
  wg.addColorStop(0, "rgba(20,25,45,0.75)");
  wg.addColorStop(1, "rgba(5,8,18,0.95)");
  ctx.fillStyle = wg;
  ctx.fillRect(0, h * 0.82, w, h * 0.18);
  for (let i = 0; i < 160; i++) {
    ctx.fillStyle = hsl(38, 0.9, 0.65, 0.25 * r());
    ctx.fillRect(r() * w, h * 0.83 + r() * h * 0.17, w * 0.02 * r(), 1.5);
  }
}

function vignette(ctx: CanvasRenderingContext2D, w: number, h: number) {
  const v = ctx.createRadialGradient(w / 2, h / 2, Math.min(w, h) * 0.35, w / 2, h / 2, Math.max(w, h) * 0.75);
  v.addColorStop(0, "rgba(0,0,0,0)");
  v.addColorStop(1, "rgba(0,0,0,0.35)");
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, w, h);
}

function exposure(ctx: CanvasRenderingContext2D, w: number, h: number, ev: number) {
  if (Math.abs(ev) < 0.05) return;
  ctx.save();
  if (ev < 0) {
    ctx.fillStyle = `rgba(0,0,0,${Math.min(0.85, -ev * 0.22)})`;
  } else {
    ctx.globalCompositeOperation = "screen";
    ctx.fillStyle = `rgba(255,255,255,${Math.min(0.7, ev * 0.2)})`;
  }
  ctx.fillRect(0, 0, w, h);
  ctx.restore();
}

export function drawScene(canvas: HTMLCanvasElement, spec: SceneSpec) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const { width: w, height: h } = canvas;
  const r = rng(spec.seed * 7919 + 13);
  switch (spec.scene) {
    case "landscape": landscape(ctx, w, h, spec, r); break;
    case "sea": sea(ctx, w, h, spec, r); break;
    case "portrait": portrait(ctx, w, h, spec, r); break;
    case "product": product(ctx, w, h, spec, r); break;
    case "city": city(ctx, w, h, spec, r); break;
  }
  vignette(ctx, w, h);
  exposure(ctx, w, h, spec.ev);
}

/** Per-pixel look: warmth, tint, contrast, saturation, fade, split toning; blended by strength. */
export function applyLook(canvas: HTMLCanvasElement, recipe: LookRecipe, strength: number) {
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx || strength <= 0) return;
  const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const d = img.data;
  const warmth = recipe.warmth ?? 0, tint = recipe.tint ?? 0, contrast = recipe.contrast ?? 0;
  const sat = recipe.saturation ?? 0, fade = recipe.fade ?? 0, split = recipe.split ?? 0;
  const k = Math.max(0, Math.min(1, strength));
  for (let i = 0; i < d.length; i += 4) {
    const r0 = d[i] / 255, g0 = d[i + 1] / 255, b0 = d[i + 2] / 255;
    let r = r0 + warmth * 0.09, g = g0 - tint * 0.05, b = b0 - warmth * 0.09;
    r = (r - 0.5) * (1 + contrast) + 0.5;
    g = (g - 0.5) * (1 + contrast) + 0.5;
    b = (b - 0.5) * (1 + contrast) + 0.5;
    const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    r = l + (r - l) * (1 + sat);
    g = l + (g - l) * (1 + sat);
    b = l + (b - l) * (1 + sat);
    if (split) {
      const hi = Math.max(0, l - 0.5) * 2, lo = Math.max(0, 0.5 - l) * 2;
      r += split * (0.1 * hi - 0.06 * lo);
      g += split * (0.03 * hi + 0.03 * lo);
      b += split * (-0.08 * hi + 0.08 * lo);
    }
    if (fade) {
      r = r * (1 - fade * 0.14) + fade * 0.07;
      g = g * (1 - fade * 0.14) + fade * 0.07;
      b = b * (1 - fade * 0.14) + fade * 0.07;
    }
    d[i] = Math.max(0, Math.min(255, (r0 + (r - r0) * k) * 255));
    d[i + 1] = Math.max(0, Math.min(255, (g0 + (g - g0) * k) * 255));
    d[i + 2] = Math.max(0, Math.min(255, (b0 + (b - b0) * k) * 255));
  }
  ctx.putImageData(img, 0, 0);
}

const cache = new Map<string, string>();
const MAX_CACHE = 600;

/** Renders (or returns the cached) JPEG data URL for a frame at `longEdge` pixels. */
export function renderFrame(key: string, spec: SceneSpec, longEdge: number, look?: { recipe: LookRecipe; strength: number } | null): string {
  const hit = cache.get(key);
  if (hit) return hit;
  const canvas = document.createElement("canvas");
  const short = Math.round((longEdge * 2) / 3);
  canvas.width = spec.tall ? short : longEdge;
  canvas.height = spec.tall ? longEdge : short;
  drawScene(canvas, spec);
  if (look) applyLook(canvas, look.recipe, look.strength);
  const url = canvas.toDataURL("image/jpeg", 0.86);
  if (cache.size > MAX_CACHE) {
    const first = cache.keys().next().value;
    if (first !== undefined) cache.delete(first);
  }
  cache.set(key, url);
  return url;
}

/** A live-view frame: the scene with a slow drift, not cached. */
export function renderLiveFrame(spec: SceneSpec, phase: number, longEdge = 960): string {
  const canvas = document.createElement("canvas");
  const short = Math.round((longEdge * 2) / 3);
  canvas.width = spec.tall ? short : longEdge;
  canvas.height = spec.tall ? longEdge : short;
  const ctx = canvas.getContext("2d");
  if (!ctx) return "";
  ctx.save();
  // Hand-held drift.
  ctx.translate(Math.sin(phase * 0.9) * 6, Math.cos(phase * 0.7) * 4);
  ctx.scale(1.02, 1.02);
  drawScene(canvas, { ...spec, t: (spec.t + Math.sin(phase * 0.05) * 0.05 + 1) % 1 });
  ctx.restore();
  return canvas.toDataURL("image/jpeg", 0.7);
}
