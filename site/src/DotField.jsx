import { useEffect, useRef } from "react";

/** 八千点: the field behind the hero is exactly this many dots. */
const TOTAL = 8000;
/** The column counts that divide it, so every row is full. */
const COLUMNS = [20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250];

const INK = "rgba(20, 22, 27, 0.2)";
const LENS = "15, 143, 156";
const GOLD = "#f5b534";
const GLYPH_FONT = '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Microsoft YaHei", sans-serif';

/** The grid of TOTAL dots, square pitch, whose height is nearest `want`. */
function fit(width, want) {
  let best = null;
  for (const cols of COLUMNS) {
    const pitch = width / cols;
    const rows = TOTAL / cols;
    const miss = Math.abs(Math.log((rows * pitch) / want));
    if (!best || miss < best.miss) best = { cols, rows, pitch, height: rows * pitch, miss };
  }
  return best;
}

const bitmaps = new Map();

/** `char` as n × n cells: 1 where its strokes cover most of the cell. */
function bitmap(char, n) {
  const key = `${char}${n}`;
  if (bitmaps.has(key)) return bitmaps.get(key);
  const scale = 6;
  const side = n * scale;
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.font = `500 ${side * 0.96}px ${GLYPH_FONT}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  /* Centred by its own ink, not by the font's line box. */
  const m = ctx.measureText(char);
  const y = side / 2 + (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent) / 2;
  ctx.fillText(char, side / 2, y);
  const pixels = ctx.getImageData(0, 0, side, side).data;
  const bits = new Uint8Array(n * n);
  for (let cy = 0; cy < n; cy += 1) {
    for (let cx = 0; cx < n; cx += 1) {
      let sum = 0;
      for (let py = 0; py < scale; py += 1) {
        const row = ((cy * scale + py) * side + cx * scale) * 4 + 3;
        for (let px = 0; px < scale; px += 1) sum += pixels[row + px * 4];
      }
      bits[cy * n + cx] = sum > scale * scale * 255 * 0.46 ? 1 : 0;
    }
  }
  bitmaps.set(key, bits);
  return bits;
}

/** The hero's backdrop: 8,000 dots on a square lattice. Those inside `slot`
 *  swell into `char`, a dot-matrix character, and re-form when it changes;
 *  dots near the pointer lean in; each `pulse` sends one ring outward.
 *  It draws only while something is changing. */
export default function DotField({ char, pulse, hostRef, slotRef }) {
  const canvasRef = useRef(null);
  const control = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const host = hostRef.current;
    const slot = slotRef.current;
    const ctx = canvas.getContext("2d");
    if (!ctx || !host || !slot) return undefined;

    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const level = new Float32Array(TOTAL); // how far each dot has swollen, 0..1
    const target = new Uint8Array(TOTAL);
    const wake = new Float64Array(TOTAL); // when each dot starts to move
    const lit = new Int32Array(TOTAL);
    const near = new Float32Array(TOTAL * 3);
    let grid = null;
    let box = null;
    let width = 0;
    let shown = "";
    let pointer = null;
    let ring = null;
    let frame = 0;
    let last = 0;
    let onScreen = true;

    const stamp = (next, instant) => {
      shown = next;
      if (!grid || !box) return;
      const bits = bitmap(next, box.size);
      const now = performance.now();
      const mid = (box.size - 1) / 2;
      for (let y = 0; y < box.size; y += 1) {
        const row = box.row + y;
        if (row < 0 || row >= grid.rows) continue;
        for (let x = 0; x < box.size; x += 1) {
          const col = box.col + x;
          if (col < 0 || col >= grid.cols) continue;
          const k = row * grid.cols + col;
          target[k] = bits[y * box.size + x];
          if (instant) level[k] = target[k];
          else wake[k] = now + (Math.hypot(x - mid, y - mid) / mid) * 150 + Math.random() * 170;
        }
      }
    };

    const draw = (now) => {
      const { cols, rows, pitch } = grid;
      const dt = Math.min(64, now - last);
      last = now;
      const rest = Math.max(0.75, pitch * 0.085);
      const full = pitch * 0.37;
      const reach = Math.max(90, pitch * 9);
      let ringAt = -1;
      let ringGain = 0;
      if (ring) {
        const t = (now - ring.start) / 1100;
        if (t >= 1) ring = null;
        else {
          ringAt = t * ring.span;
          ringGain = (1 - t) * (1 - t);
        }
      }
      const band = pitch * 2.4;
      let moving = false;
      let lits = 0;
      let nears = 0;

      ctx.clearRect(0, 0, width, grid.height);
      ctx.fillStyle = INK;
      ctx.beginPath();
      for (let row = 0; row < rows; row += 1) {
        const y = (row + 0.5) * pitch;
        for (let col = 0; col < cols; col += 1) {
          const k = row * cols + col;
          let lv = level[k];
          if (lv !== target[k]) {
            if (now >= wake[k]) {
              const step = dt / 260;
              lv = target[k] ? Math.min(1, lv + step) : Math.max(0, lv - step);
              level[k] = lv;
            }
            moving = true;
          }
          if (lv > 0) {
            lit[lits] = k;
            lits += 1;
            continue;
          }
          const x = (col + 0.5) * pitch;
          let r = rest;
          if (pointer) {
            const d = Math.hypot(x - pointer.x, y - pointer.y);
            if (d < reach) {
              const f = 1 - d / reach;
              r += f * f * pitch * 0.2;
              near[nears] = x;
              near[nears + 1] = y;
              near[nears + 2] = f;
              nears += 3;
            }
          }
          if (ringAt >= 0) {
            const off = Math.abs(Math.hypot(x - ring.x, y - ring.y) - ringAt);
            if (off < band) r += (1 - off / band) * ringGain * pitch * 0.2;
          }
          ctx.moveTo(x + r, y);
          ctx.arc(x, y, r, 0, Math.PI * 2);
        }
      }
      ctx.fill();

      /* The pointer's lens, tinted. */
      for (let i = 0; i < nears; i += 3) {
        const f = near[i + 2];
        ctx.fillStyle = `rgba(${LENS}, ${(f * 0.75).toFixed(3)})`;
        ctx.beginPath();
        ctx.arc(near[i], near[i + 1], rest + f * f * pitch * 0.2, 0, Math.PI * 2);
        ctx.fill();
      }

      /* The character: the icon's teal running to its indigo. */
      if (box && lits) {
        const x0 = box.col * pitch;
        const y0 = box.row * pitch;
        const span = box.size * pitch;
        const ink = ctx.createLinearGradient(x0, y0, x0 + span, y0 + span);
        ink.addColorStop(0, "#0f9aa3");
        ink.addColorStop(0.55, "#2a62b6");
        ink.addColorStop(1, "#3a3fa8");
        ctx.fillStyle = ink;
        ctx.beginPath();
        for (let i = 0; i < lits; i += 1) {
          const k = lit[i];
          const lv = level[k];
          const eased = lv * lv * (3 - 2 * lv);
          const x = ((k % cols) + 0.5) * pitch;
          const y = (Math.floor(k / cols) + 0.5) * pitch;
          const r = rest + (full - rest) * eased;
          ctx.moveTo(x + r, y);
          ctx.arc(x, y, r, 0, Math.PI * 2);
        }
        ctx.fill();
      }

      /* And the icon's gold dot, at the character's lower right. */
      if (box) {
        const x = (box.col + box.size + 2) * pitch;
        const y = (box.row + box.size - 1.5) * pitch;
        let r = pitch * 1.3;
        if (ringAt >= 0) r *= 1 + ringGain * 0.22 * Math.max(0, 1 - ringAt / (pitch * 14));
        ctx.fillStyle = GOLD;
        ctx.beginPath();
        ctx.arc(x, y, r, 0, Math.PI * 2);
        ctx.fill();
      }
      return moving || ring !== null;
    };

    const tick = (now) => {
      frame = 0;
      if (!grid) return;
      if (draw(now) && onScreen) frame = requestAnimationFrame(tick);
    };
    const kick = () => {
      if (!frame && onScreen) {
        last = performance.now();
        frame = requestAnimationFrame(tick);
      }
    };

    const measure = () => {
      const w = host.clientWidth;
      if (!w) return;
      width = w;
      grid = fit(w, host.offsetHeight);
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(grid.height * dpr);
      canvas.style.height = `${grid.height}px`;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const origin = canvas.getBoundingClientRect();
      const place = slot.getBoundingClientRect();
      box = {
        size: Math.max(16, Math.min(44, Math.round(place.width / grid.pitch))),
        col: Math.round((place.left - origin.left) / grid.pitch),
        row: Math.round((place.top - origin.top) / grid.pitch),
      };
      level.fill(0);
      target.fill(0);
      if (shown) stamp(shown, true);
      last = performance.now();
      draw(last);
    };

    const onMove = (event) => {
      const origin = canvas.getBoundingClientRect();
      const y = event.clientY - origin.top;
      const inside = y > -120 && y < origin.height + 120;
      if (!inside && !pointer) return;
      pointer = inside ? { x: event.clientX - origin.left, y } : null;
      kick();
    };
    const onLeave = () => {
      if (!pointer) return;
      pointer = null;
      kick();
    };

    control.current = {
      show(next) {
        if (!next || next === shown) return;
        stamp(next, still || !grid);
        kick();
      },
      ring() {
        if (still || !grid || !box) return;
        const mid = box.size / 2;
        ring = {
          start: performance.now(),
          x: (box.col + mid) * grid.pitch,
          y: (box.row + mid) * grid.pitch,
          span: Math.max(width, grid.height) * 0.6,
        };
        kick();
      },
    };

    shown = "";
    measure();
    const resize = new ResizeObserver(measure);
    resize.observe(host);
    const watch = new IntersectionObserver(([entry]) => {
      onScreen = entry.isIntersecting;
      if (onScreen) kick();
    });
    watch.observe(canvas);
    window.addEventListener("pointermove", onMove, { passive: true });
    document.documentElement.addEventListener("pointerleave", onLeave);

    return () => {
      control.current = null;
      cancelAnimationFrame(frame);
      resize.disconnect();
      watch.disconnect();
      window.removeEventListener("pointermove", onMove);
      document.documentElement.removeEventListener("pointerleave", onLeave);
    };
  }, [hostRef, slotRef]);

  useEffect(() => {
    control.current?.show(char);
  }, [char]);

  useEffect(() => {
    if (pulse) control.current?.ring();
  }, [pulse]);

  return <canvas className="dotfield" ref={canvasRef} aria-hidden="true" />;
}
