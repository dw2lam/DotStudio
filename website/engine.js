/* ============================================================================
   DotStudio — in-browser effects engine
   A small real-time renderer that mirrors the macOS app's effects so the whole
   site IS the product. One animated "source" field is fed through canvas
   shaders: dither, ASCII, halftone, dots, matrix, scanlines, VHS, voronoi,
   thermal, Game Boy and neon edges.

   Pixel-grade effects (dither / gameboy / thermal / scanlines / vhs / voronoi)
   render into a tiny offscreen ImageData buffer and scale up crisp — fast.
   Vector effects (halftone / dots / ascii / matrix / neon) draw shapes & glyphs
   directly because their cells are large.
============================================================================ */
(function (global) {
  "use strict";

  const REDUCE = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ----------------------------- math + color ----------------------------- */
  const clamp = (x, a = 0, b = 1) => (x < a ? a : x > b ? b : x);
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); };
  const TAU = Math.PI * 2;

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // brand aurora ramp: deep navy → indigo → teal → cyan → CRT green → mint
  const BRAND = [
    [0.00, [6, 9, 19]],
    [0.26, [17, 23, 60]],
    [0.48, [13, 78, 116]],
    [0.66, [20, 152, 162]],
    [0.81, [51, 230, 255]],
    [0.92, [78, 255, 150]],
    [1.00, [201, 255, 222]],
  ];
  const THERMAL = [
    [0.00, [3, 2, 12]],
    [0.18, [38, 9, 74]],
    [0.40, [120, 20, 120]],
    [0.58, [221, 40, 70]],
    [0.74, [255, 110, 22]],
    [0.88, [255, 201, 44]],
    [1.00, [255, 255, 232]],
  ];
  // Game Boy DMG 4-tone
  const GB = [[15, 56, 15], [48, 98, 48], [139, 172, 15], [155, 188, 15]];

  function ramp(stops, t) {
    t = clamp(t);
    for (let i = 1; i < stops.length; i++) {
      if (t <= stops[i][0]) {
        const a = stops[i - 1], b = stops[i];
        const k = (t - a[0]) / (b[0] - a[0]);
        return [
          lerp(a[1][0], b[1][0], k),
          lerp(a[1][1], b[1][1], k),
          lerp(a[1][2], b[1][2], k),
        ];
      }
    }
    return stops[stops.length - 1][1].slice();
  }
  const brand = (t) => ramp(BRAND, t);
  const thermal = (t) => ramp(THERMAL, t);

  /* ---- tiny 3-vector + tone helpers (for the black hole) ---- */
  const v3len = (a) => Math.hypot(a[0], a[1], a[2]);
  const v3norm = (a) => { const l = v3len(a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
  const v3cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  function blackbodyCol(tk) {
    const t = clamp((tk - 1000) / 9000);
    const red = clamp(1 - (t - 0.8) * 2, 0.5, 1);
    const green = smooth(0, 0.5, t) * (1 - Math.max((t - 0.7) * 0.3, 0));
    const blue = smooth(0.3, 1, t) * t;
    return [red, green, blue];
  }
  const acesCh = (v) => clamp((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14));

  function hexRgb(h) {
    h = h.replace("#", "");
    if (h.length === 3) h = h.split("").map((c) => c + c).join("");
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  const rgbStr = (c) => `rgb(${c[0] | 0},${c[1] | 0},${c[2] | 0})`;

  /* ------------------------------- sources -------------------------------- */
  // Each source returns luminance L in [0,1] for normalized (u,v) at time t(sec).
  const SOURCES = {
    // domain-warped metaballs drifting over a breathing diagonal ramp
    aurora(u, v, t) {
      const s = t * 0.06;
      const wx = u + 0.07 * Math.sin(v * 3.1 + s * 6.0);
      const wy = v + 0.07 * Math.cos(u * 3.0 - s * 5.0);
      const well = (cx, cy, r) => {
        const dx = wx - cx, dy = wy - cy;
        return Math.exp(-(dx * dx + dy * dy) / (r * r));
      };
      let m = 0;
      m += 1.00 * well(0.30 + 0.18 * Math.sin(s * 1.7), 0.42 + 0.16 * Math.cos(s * 1.3), 0.33);
      m += 0.85 * well(0.72 + 0.16 * Math.cos(s * 1.1 + 1.0), 0.60 + 0.18 * Math.sin(s * 1.6 + 0.5), 0.29);
      m += 0.66 * well(0.52 + 0.22 * Math.sin(s * 0.9 + 2.0), 0.30 + 0.20 * Math.sin(s * 1.9 + 1.5), 0.25);
      const grad = 0.5 + 0.5 * Math.sin((u * 1.2 - v * 0.9 + s * 2.0) * Math.PI);
      return clamp(0.12 + 0.66 * m + 0.24 * grad);
    },
    // tighter swirl for warp-style looks
    swirl(u, v, t) {
      const cx = u - 0.5, cy = v - 0.5;
      const r = Math.hypot(cx, cy);
      const a = Math.atan2(cy, cx) + r * 6.0 - t * 0.4;
      return clamp(0.5 + 0.5 * Math.sin(a * 3.0) * (1 - r) + 0.25 * Math.sin(r * 14 - t));
    },
  };

  /* ----------------------------- glyph ramps ------------------------------ */
  const ASCII_RAMP = " .:-=+*o#%@".split("");
  const ASCII_FINE = " .'`^\",:Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$".split("");
  const KATA = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾅﾆﾇﾐﾑﾒ0123456789Z:.=*+-".split("");

  /* --------------------------- effect renderers --------------------------- */
  // Vector effects draw on the main ctx. Pixel effects fill c.buf ImageData.
  const EFFECTS = {

    /* ---- PIXEL effects (write into low-res buffer) ---- */
    dither: { pixel: true, cell: 2.4, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const fg = hexRgb(P.fg || "#46ffa0"), bg = hexRgb(P.bg || "#0a0f1e");
      const BAYER = [0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5];
      const levels = P.levels || 2;
      const mono = P.mono !== 0;
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const L = c.src(x / bw, y / bh, t);
        const thr = (BAYER[(x & 3) + (y & 3) * 4] + 0.5) / 16;
        let r, g, b;
        if (mono) {
          const on = L > thr;
          r = on ? fg[0] : bg[0]; g = on ? fg[1] : bg[1]; b = on ? fg[2] : bg[2];
        } else {
          const q = Math.floor(clamp(L + (thr - 0.5) / levels) * (levels - 1) + 0.5) / (levels - 1);
          const col = brand(q); r = col[0]; g = col[1]; b = col[2];
        }
        data[i++] = r; data[i++] = g; data[i++] = b; data[i++] = 255;
      }
      c.flush();
    }},

    gameboy: { pixel: true, cell: 4.2, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const BAYER = [0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5];
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const L = c.src(x / bw, y / bh, t);
        const d = (BAYER[(x & 3) + (y & 3) * 4] + 0.5) / 16 - 0.5;
        const idx = clamp(Math.floor((L + d / (P.dither || 2)) * 4), 0, 3) | 0;
        const col = GB[idx];
        data[i++] = col[0]; data[i++] = col[1]; data[i++] = col[2]; data[i++] = 255;
      }
      c.flush();
    }},

    thermal: { pixel: true, cell: 3.0, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const gain = P.gain || 1;
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const L = clamp(c.src(x / bw, y / bh, t) * gain);
        const col = thermal(L);
        data[i++] = col[0]; data[i++] = col[1]; data[i++] = col[2]; data[i++] = 255;
      }
      c.flush();
    }},

    scanlines: { pixel: true, cell: 2.2, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      let i = 0;
      for (let y = 0; y < bh; y++) {
        const sl = 0.62 + 0.38 * (y % 3 === 0 ? 0 : 1);
        for (let x = 0; x < bw; x++) {
          const L = c.src(x / bw, y / bh, t);
          const col = brand(clamp(L * 1.04));
          data[i++] = col[0] * sl; data[i++] = col[1] * sl; data[i++] = col[2] * sl; data[i++] = 255;
        }
      }
      c.flush();
    }},

    vhs: { pixel: true, cell: 2.4, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const amt = (P.amount == null ? 1 : P.amount);
      const band = (Math.sin(t * 2.3) * 0.5 + 0.5);
      let i = 0;
      for (let y = 0; y < bh; y++) {
        const yy = y / bh;
        // rolling tracking band + horizontal jitter
        const inBand = Math.abs(((yy + t * 0.18) % 1) - band) < 0.06 ? 1 : 0;
        const jitter = (Math.sin(y * 0.7 + t * 9) * 0.012 + inBand * 0.05) * amt;
        const sl = y % 2 === 0 ? 1 : 0.78;
        for (let x = 0; x < bw; x++) {
          const xx = x / bw + jitter;
          const sh = 0.012 * amt;
          const r = brand(c.src(xx + sh, yy, t))[0];
          const g = brand(c.src(xx, yy, t))[1];
          const b = brand(c.src(xx - sh, yy, t))[2];
          const n = inBand ? 40 * Math.random() : 0;
          data[i++] = clamp((r + n) * sl, 0, 255);
          data[i++] = clamp((g + n) * sl, 0, 255);
          data[i++] = clamp((b + n) * sl, 0, 255);
          data[i++] = 255;
        }
      }
      c.flush();
    }},

    voronoi: { pixel: true, cell: 3.4, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const seeds = c.seeds(P.count || 26);
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const u = x / bw, v = y / bh;
        let d1 = 1e9, d2 = 1e9, hit = 0;
        for (let s = 0; s < seeds.length; s++) {
          const dx = u - seeds[s].x, dy = (v - seeds[s].y) * 1.0;
          const d = dx * dx + dy * dy;
          if (d < d1) { d2 = d1; d1 = d; hit = s; } else if (d < d2) d2 = d;
        }
        const edge = smooth(0.0, 0.0009, Math.sqrt(d2) - Math.sqrt(d1));
        const L = c.src(seeds[hit].x, seeds[hit].y, t);
        const col = brand(clamp(L * 0.9 + 0.1));
        const e = 0.35 + 0.65 * edge;
        data[i++] = col[0] * e; data[i++] = col[1] * e; data[i++] = col[2] * e; data[i++] = 255;
      }
      c.flush();
    }},

    /* ---- VECTOR effects (draw on main ctx) ---- */
    halftone: { cell: 9, paint(c, P) {
      const ctx = c.ctx, cell = c.cellPx(P.cell || 9), t = c.t();
      const dotMax = cell * 0.62;
      const fg = P.fg || "#46ffa0", bg = P.bg || "#070b16";
      ctx.fillStyle = bg; ctx.fillRect(0, 0, c.w, c.h);
      ctx.fillStyle = fg;
      const ang = P.angle != null ? P.angle : 0.4;
      const ca = Math.cos(ang), sa = Math.sin(ang);
      for (let y = cell / 2; y < c.h + cell; y += cell)
        for (let x = cell / 2; x < c.w + cell; x += cell) {
          // sample on a slightly rotated grid for the classic screen angle
          const u = (x * ca - y * sa) / c.w, v = (x * sa + y * ca) / c.h;
          const L = c.src(clamp(u), clamp(v), t);
          const r = dotMax * Math.sqrt(clamp(L));
          if (r < 0.3) continue;
          ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill();
        }
    }},

    dots: { cell: 12, paint(c, P) {
      const ctx = c.ctx, cell = c.cellPx(P.cell || 12), t = c.t();
      ctx.fillStyle = "#070b16"; ctx.fillRect(0, 0, c.w, c.h);
      for (let y = cell / 2; y < c.h + cell; y += cell)
        for (let x = cell / 2; x < c.w + cell; x += cell) {
          const L = c.src(x / c.w, y / c.h, t);
          const r = cell * 0.52 * clamp(L * 1.05);
          if (r < 0.3) continue;
          ctx.fillStyle = rgbStr(brand(clamp(L * 0.85 + 0.12)));
          ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill();
        }
    }},

    ascii: { cell: 12, paint(c, P) {
      const ctx = c.ctx, cell = c.cellPx(P.cell || 12), t = c.t();
      const set = P.fine ? ASCII_FINE : ASCII_RAMP;
      ctx.fillStyle = "#05080f"; ctx.fillRect(0, 0, c.w, c.h);
      ctx.font = `${(cell * 1.05) | 0}px ui-monospace, "SFMono-Regular", "JetBrains Mono", monospace`;
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      const color = P.color !== 0;
      if (!color) ctx.fillStyle = P.fg || "#46ffa0";
      for (let y = cell / 2; y < c.h + cell / 2; y += cell)
        for (let x = cell / 2; x < c.w + cell / 2; x += cell) {
          const L = c.src(x / c.w, y / c.h, t);
          const gi = clamp(Math.floor(L * (set.length - 1)), 0, set.length - 1);
          const ch = set[gi];
          if (ch === " ") continue;
          if (color) ctx.fillStyle = rgbStr(brand(clamp(L * 0.8 + 0.2)));
          ctx.fillText(ch, x, y + 0.5);
        }
    }},

    matrix: { cell: 14, paint(c, P) {
      const ctx = c.ctx, cell = c.cellPx(P.cell || 14), t = c.t();
      const cols = Math.ceil(c.w / cell), rows = Math.ceil(c.h / cell);
      const st = c.matrix(cols, rows, P.speed || 1);
      // fade trails
      ctx.fillStyle = "rgba(2,7,5,0.22)"; ctx.fillRect(0, 0, c.w, c.h);
      ctx.font = `${(cell * 1.0) | 0}px ui-monospace, "JetBrains Mono", monospace`;
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      const reveal = P.reveal !== 0;
      for (let cx = 0; cx < cols; cx++) {
        const head = st.drops[cx];
        for (let k = 0; k < 14; k++) {
          const cy = Math.floor(head) - k;
          if (cy < 0 || cy >= rows) continue;
          const x = cx * cell + cell / 2, y = cy * cell + cell / 2;
          const L = reveal ? c.src(x / c.w, y / c.h, t) : 1;
          if (reveal && L < 0.16) continue;
          const ch = KATA[(st.seed[cx] + cy * 7 + (k === 0 ? (t * 6 | 0) : 0)) % KATA.length];
          if (k === 0) ctx.fillStyle = "#daffe9";
          else ctx.fillStyle = `rgba(${40 + 30 * L | 0},255,${120 + 60 * L | 0},${clamp(1 - k / 13) * (0.4 + 0.6 * L)})`;
          ctx.fillText(ch, x, y);
        }
        st.drops[cx] += st.vel[cx];
        if (st.drops[cx] - 14 > rows && Math.random() > 0.965) st.drops[cx] = 0;
      }
    }},

    neon: { cell: 4, paint(c, P) {
      const t = c.t();
      const bw = Math.min(360, Math.ceil(c.w / c.cellPx(P.cell || 4)));
      const bh = Math.ceil(bw * c.h / c.w);
      const off = c.scratch(bw, bh), octx = off.getContext("2d");
      const img = octx.createImageData(bw, bh), data = img.data;
      const gain = P.gain || 3;
      const du = 1 / bw, dv = 1 / bh;
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const u = x / bw, v = y / bh;
        const L = c.src(u, v, t);
        const gx = c.src(u + du, v, t) - L, gy = c.src(u, v + dv, t) - L;
        const mag = clamp(Math.sqrt(gx * gx + gy * gy) * 26 * gain);
        const e = smooth(0.12, 0.6, mag);
        const col = brand(clamp(0.55 + 0.45 * L));
        data[i++] = col[0] * e; data[i++] = col[1] * e; data[i++] = col[2] * e; data[i++] = 255;
      }
      octx.putImageData(img, 0, 0);
      const ctx = c.ctx;
      ctx.fillStyle = "#04060c"; ctx.fillRect(0, 0, c.w, c.h);
      ctx.imageSmoothingEnabled = true;
      ctx.globalCompositeOperation = "lighter";
      ctx.filter = "blur(6px)"; ctx.drawImage(off, 0, 0, c.w, c.h);
      ctx.filter = "none"; ctx.drawImage(off, 0, 0, c.w, c.h);
      ctx.globalCompositeOperation = "source-over";
    }},

    hex: { cell: 18, paint(c, P) {
      const ctx = c.ctx, t = c.t();
      const R = c.cellPx(P.cell || 18) * 0.6;     // hex radius
      const hw = Math.sqrt(3) * R, vh = 1.5 * R;
      ctx.fillStyle = "#070b16"; ctx.fillRect(0, 0, c.w, c.h);
      let row = 0;
      for (let y = -R; y < c.h + R; y += vh, row++) {
        const xoff = row % 2 ? hw / 2 : 0;
        for (let x = -R + xoff; x < c.w + hw; x += hw) {
          const L = c.src(clamp(x / c.w), clamp(y / c.h), t);
          ctx.fillStyle = rgbStr(brand(clamp(L * 0.9 + 0.08)));
          ctx.beginPath();
          for (let a = 0; a < 6; a++) {
            const ang = Math.PI / 180 * (60 * a - 30);
            const px = x + R * 0.92 * Math.cos(ang), py = y + R * 0.92 * Math.sin(ang);
            a ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
          }
          ctx.closePath(); ctx.fill();
        }
      }
    }},

    /* ---- Starfield: flying through stars ---- */
    starfield: { cell: 6, paint(c, P) {
      const ctx = c.ctx, t = c.t();
      const st = c.stars(P.count || 240);
      ctx.fillStyle = "#04060c"; ctx.fillRect(0, 0, c.w, c.h);
      const cx = c.w / 2, cy = c.h / 2, maxR = Math.hypot(cx, cy);
      const speed = P.speed || 1, warp = (P.warp == null ? 0.45 : P.warp);
      ctx.lineCap = "round";
      for (const s of st) {
        const z = (s.z + t * speed * 0.12) % 1;
        const r = z * z * maxR * 1.08;
        const x = cx + Math.cos(s.a) * r, y = cy + Math.sin(s.a) * r;
        if (x < -12 || x > c.w + 12 || y < -12 || y > c.h + 12) continue;
        const size = (0.5 + s.b * 1.7) * z * c.dpr;
        ctx.globalAlpha = clamp(z * 1.5) * (0.45 + 0.55 * s.b);
        if (warp > 0.05 && z > 0.28) {
          const r2 = Math.max(0, r - warp * 46 * z * c.dpr);
          ctx.strokeStyle = s.col; ctx.lineWidth = size;
          ctx.beginPath(); ctx.moveTo(cx + Math.cos(s.a) * r2, cy + Math.sin(s.a) * r2); ctx.lineTo(x, y); ctx.stroke();
        } else {
          ctx.fillStyle = s.col; ctx.beginPath(); ctx.arc(x, y, size, 0, TAU); ctx.fill();
        }
      }
      ctx.globalAlpha = 1;
    }},

    /* ---- Black Hole: gravitational lensing + accretion disk (low-res raymarch) ---- */
    blackhole: { cell: 8, fps: 36, paint(c, P) {
      const t = c.t();
      const BW = 188, BH = Math.max(8, Math.round(BW * c.h / c.w));
      const off = c.scratch(BW, BH), octx = off.getContext("2d");
      const img = octx.createImageData(BW, BH), data = img.data;
      const mass = P.mass || 0.4, brightness = P.brightness || 5;
      const rot = (P.rot == null ? -8.7 : P.rot), diskScale = P.disk || 1;
      const speed = (P.speed == null ? 1 : P.speed), starsAmt = (P.stars == null ? 1 : P.stars);
      const angle = clamp(P.angle == null ? 0.22 : P.angle, 0.03, 1.45);
      const ce = Math.cos(angle), se = Math.sin(angle);
      const ts = t * speed;
      const rs = mass * 2, innerR = 4.1 * diskScale, outerR = 14.5 * diskScale;
      const ct = ts * 0.025;
      const cam = [Math.sin(ct) * 20 * ce, -se * 20, -Math.cos(ct) * 20 * ce];
      const fwd = v3norm([-cam[0], -cam[1], -cam[2]]);
      const right = v3norm(v3cross([0, 1, 0], fwd));
      const up = v3cross(fwd, right);
      const aspect = c.w / c.h, cyc = ts % 5, rotSign = Math.sign(rot);
      let i = 0;
      for (let y = 0; y < BH; y++) for (let x = 0; x < BW; x++) {
        let px = ((x + 0.5) / BW - 0.5) * 2, py = -((y + 0.5) / BH - 0.5) * 2; px *= aspect;
        let rd = v3norm([fwd[0] + right[0] * px + up[0] * py, fwd[1] + right[1] * px + up[1] * py, fwd[2] + right[2] * px + up[2] * py]);
        let rp = cam.slice(), prev = cam.slice();
        let aR = 0, aG = 0, aB = 0, alpha = 0, captured = 0;
        for (let s = 0; s < 26; s++) {
          if (alpha > 0.99) break;
          const r = v3len(rp);
          if (r < rs * 1.01) { captured = 1; break; }
          if (r > 60) break;
          const bend = rs / (r * r) * 2.4;
          rd = v3norm([rd[0] - rp[0] / r * bend, rd[1] - rp[1] / r * bend, rd[2] - rp[2] / r * bend]);
          prev = rp; rp = [rp[0] + rd[0], rp[1] + rd[1], rp[2] + rd[2]];
          if (prev[1] * rp[1] < 0) {
            const tt = -prev[1] / (rp[1] - prev[1]);
            const hx = prev[0] + (rp[0] - prev[0]) * tt, hz = prev[2] + (rp[2] - prev[2]) * tt;
            const hr = Math.hypot(hx, hz);
            if (hr > innerR && hr < outerR) {
              const ang = Math.atan2(hz, hx);
              const nr = clamp((hr - innerR) / (outerR - innerR));
              const tf = Math.pow(innerR / hr, 5.22);
              const dc0 = blackbodyCol(lerp(1500, 49780, tf));
              const dl = dc0[0] * 0.3 + dc0[1] * 0.59 + dc0[2] * 0.11;   // softer, warmer palette
              const dc = [lerp(dc0[0], dl, 0.4), lerp(dc0[1], dl * 0.9, 0.4), lerp(dc0[2], dl * 0.74, 0.4)];
              const beta = (1 / Math.sqrt(hr / innerR)) * 0.3;
              const cosT = (-Math.sin(ang) * rotSign) * rd[0] + (Math.cos(ang) * rotSign) * rd[2];
              const dopp = Math.pow(clamp(1 / (1 - beta * cosT), 0.1, 5), 3);
              const edge = smooth(0, 0.18, nr) * smooth(1, 0.5, nr);
              const ph = ang + cyc * rot / Math.pow(hr, 1.5);
              const tb = 0.5 + 0.3 * Math.sin(hr * 2.1 + ph * 3) + 0.2 * Math.sin(ph * 5 + hr * 0.7 + t);
              const op = Math.pow(clamp(tb), 3.4) * edge;
              const rem = 1 - alpha, k = brightness * op * rem * dopp;
              aR += dc[0] * k; aG += dc[1] * k; aB += dc[2] * k; alpha += rem * op;
            }
          }
        }
        if (!captured && alpha < 0.99) {
          const h = Math.sin(rd[0] * 173.1 + rd[1] * 311.7 + rd[2] * 97.3) * 43758.5;
          const star = (h - Math.floor(h)) > (1 - 0.009 * starsAmt) ? 0.9 * (1 - alpha) * starsAmt : 0;
          aR += star; aG += star; aB += star;
        }
        data[i++] = acesCh(aR) * 255; data[i++] = acesCh(aG) * 255; data[i++] = acesCh(aB) * 255; data[i++] = 255;
      }
      octx.putImageData(img, 0, 0);
      const ctx = c.ctx;
      ctx.fillStyle = "#000"; ctx.fillRect(0, 0, c.w, c.h);
      ctx.imageSmoothingEnabled = true;
      // bloom: two blur radii added, then the sharp image on top
      ctx.globalCompositeOperation = "lighter";
      ctx.filter = "blur(14px)"; ctx.drawImage(off, 0, 0, c.w, c.h);
      ctx.filter = "blur(5px)"; ctx.drawImage(off, 0, 0, c.w, c.h);
      ctx.filter = "none"; ctx.globalCompositeOperation = "source-over";
      ctx.drawImage(off, 0, 0, c.w, c.h);
    }},

    /* ---- Universe: top-down heliocentric solar system ---- */
    universe: { cell: 6, fps: 40, paint(c, P) {
      const ctx = c.ctx, t = c.t();
      const W = c.w, H = c.h, cx = W / 2, cy = H / 2, base = Math.min(W, H);
      const scale = (P.scale == null ? 1 : P.scale), speed = (P.speed == null ? 1 : P.speed);
      const tilt = 0.82;
      ctx.fillStyle = "#05060c"; ctx.fillRect(0, 0, W, H);
      // planets: [orbitFrac, sizeFrac, [r,g,b], orbitSpeed, ring]
      const PL = [
        [0.085, 0.006, [150,150,158], 1.60, 0],
        [0.130, 0.011, [216,193,136], 1.18, 0],
        [0.175, 0.013, [60,134,200],  1.00, 0],
        [0.225, 0.009, [200,90,50],   0.81, 0],
        [0.300, 0.026, [216,180,138], 0.44, 0],
        [0.370, 0.022, [216,200,154], 0.32, 1],
        [0.430, 0.016, [159,224,232], 0.23, 0],
        [0.490, 0.015, [74,111,208],  0.18, 0],
      ];
      // orbit rings
      if (P.orbits !== 0) {
        ctx.strokeStyle = "rgba(120,120,135,0.32)"; ctx.lineWidth = Math.max(1, base * 0.0012);
        for (const pl of PL) {
          const R = pl[0] * base * scale;
          ctx.beginPath(); ctx.ellipse(cx, cy, R, R * tilt, 0, 0, TAU); ctx.stroke();
        }
      }
      // sun glow
      const sunR = 0.05 * base * scale;
      const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, sunR * 3.2);
      g.addColorStop(0, "rgba(255,252,238,1)"); g.addColorStop(0.28, "rgba(255,205,110,0.95)");
      g.addColorStop(0.7, "rgba(255,130,50,0.4)"); g.addColorStop(1, "rgba(255,120,40,0)");
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(cx, cy, sunR * 3.2, 0, TAU); ctx.fill();
      // planets
      for (let i = 0; i < PL.length; i++) {
        const [of_, sf, col, osp, ring] = PL[i];
        const a = t * speed * 0.1 * osp + i * 1.7;
        const R = of_ * base * scale, sz = Math.max(2, sf * base * scale);
        const x = cx + Math.cos(a) * R, y = cy + Math.sin(a) * R * tilt;
        if (ring) {
          ctx.strokeStyle = "rgba(210,196,150,0.65)"; ctx.lineWidth = Math.max(1, sz * 0.35);
          ctx.beginPath(); ctx.ellipse(x, y, sz * 2.0, sz * 2.0 * 0.4, 0, 0, TAU); ctx.stroke();
        }
        const dx = (cx - x), dy = (cy - y), dl = Math.hypot(dx, dy) || 1;
        const hx = x + dx / dl * sz * 0.45, hy = y + dy / dl * sz * 0.45;
        const pg = ctx.createRadialGradient(hx, hy, sz * 0.1, x, y, sz);
        pg.addColorStop(0, `rgb(${Math.min(255,col[0]*1.35)|0},${Math.min(255,col[1]*1.35)|0},${Math.min(255,col[2]*1.35)|0})`);
        pg.addColorStop(0.65, rgbStr(col));
        pg.addColorStop(1, `rgb(${col[0]*0.25|0},${col[1]*0.25|0},${col[2]*0.25|0})`);
        ctx.fillStyle = pg; ctx.beginPath(); ctx.arc(x, y, sz, 0, TAU); ctx.fill();
        if (i === 2) {  // Earth — tiny pulsing location marker
          const pulse = 0.5 + 0.5 * Math.sin(t * 3);
          ctx.fillStyle = `rgba(80,255,120,${0.5 + 0.4 * pulse})`;
          ctx.beginPath(); ctx.arc(x - sz * 0.3, y - sz * 0.2, Math.max(1, sz * 0.28), 0, TAU); ctx.fill();
        }
      }
    }},

    /* ---- NES 8-Bit: palette quantize + scanlines ---- */
    nes: { pixel: true, cell: 4.5, paint(c, P) {
      const { bw, bh, data, t } = c.px();
      const PAL = [[16,24,64],[24,96,160],[44,168,168],[88,184,96],[208,184,96],[238,242,214]];
      const scan = (P.scan == null ? 0.32 : P.scan);
      let i = 0;
      for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
        const L = c.src(x / bw, y / bh, t);
        const col = PAL[clamp(Math.floor(L * PAL.length), 0, PAL.length - 1) | 0];
        const s = 1 - scan * (y % 2);
        data[i++] = col[0] * s; data[i++] = col[1] * s; data[i++] = col[2] * s; data[i++] = 255;
      }
      c.flush();
    }},
  };

  const EFFECT_ORDER = ["ascii", "halftone", "dither", "matrix", "dots", "thermal", "neon", "voronoi", "hex", "gameboy", "scanlines", "vhs", "nes", "starfield", "universe", "blackhole"];
  const EFFECT_LABEL = {
    ascii: "ASCII", halftone: "Halftone", dither: "Dithering", matrix: "Matrix Rain",
    dots: "Dots", thermal: "Thermal", neon: "Neon Edges", voronoi: "Voronoi",
    hex: "Hex Mosaic", gameboy: "Game Boy", scanlines: "Phosphor", vhs: "VHS",
    nes: "NES 8-Bit", starfield: "Starfield", universe: "Universe", blackhole: "Black Hole",
  };

  /* --------------------------- canvas controller -------------------------- */
  class DotCanvas {
    constructor(el, opts = {}) {
      this.canvas = el;
      this.ctx = el.getContext("2d", { alpha: false });
      this.effect = opts.effect || el.dataset.effect || "ascii";
      this.sourceName = opts.source || el.dataset.source || "aurora";
      this.params = opts.params || {};
      this.staticFrame = !!opts.static || el.hasAttribute("data-static") || REDUCE;
      this.fpsCap = opts.fps || (el.dataset.fps ? +el.dataset.fps : (el.dataset.role === "tile" ? 30 : 60));
      this._last = 0; this._t0 = 0; this.visible = false; this.paused = false; this._state = {};
      this.dpr = Math.min(2, global.devicePixelRatio || 1);
      this.resize();
      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(el);
    }
    resize() {
      const r = this.canvas.getBoundingClientRect();
      const w = Math.max(2, r.width), h = Math.max(2, r.height);
      this.cssW = w; this.cssH = h;
      this.w = Math.round(w * this.dpr); this.h = Math.round(h * this.dpr);
      if (this.canvas.width !== this.w) this.canvas.width = this.w;
      if (this.canvas.height !== this.h) this.canvas.height = this.h;
      this._state = {};            // grids depend on size
      if (this.staticFrame) this.render(0.6);
    }
    setEffect(name) {
      if (name === this.effect) return;
      this.effect = name; this._state = {};
      // repaint the new effect immediately so live crossfades never blank out
      this.render(this.staticFrame ? 0.6 : (this._t || 0.6));
    }
    setParams(p) { this.params = p; this._state = {}; if (this.staticFrame || this.visible) this.render(this._t || 0.6); }
    setSource(name) { this.sourceName = name; this._state = {}; if (this.staticFrame) this.render(this._t || 0.6); }

    /* helpers exposed to effects */
    t() { return this._t; }
    src(u, v, t) { return (SOURCES[this.sourceName] || SOURCES.aurora)(u, v, t); }
    cellPx(cssCell) { return Math.max(2, cssCell * this.dpr); }
    px() {
      const def = EFFECTS[this.effect];
      const cell = this.cellPx(this.params.cell || def.cell);
      const bw = Math.min(420, Math.max(8, Math.round(this.w / cell)));
      const bh = Math.max(6, Math.round(bw * this.h / this.w));
      this._buf = this.scratch(bw, bh);
      this._bctx = this._buf.getContext("2d");
      this._img = this._bctx.createImageData(bw, bh);
      return { bw, bh, data: this._img.data, t: this._t };
    }
    flush() {
      this._bctx.putImageData(this._img, 0, 0);
      this.ctx.imageSmoothingEnabled = false;
      this.ctx.drawImage(this._buf, 0, 0, this.w, this.h);
    }
    scratch(w, h) {
      let s = this._scratchEl;
      if (!s) { s = this._scratchEl = document.createElement("canvas"); }
      if (s.width !== w) s.width = w;
      if (s.height !== h) s.height = h;
      return s;
    }
    matrix(cols, rows, speed) {
      let m = this._state.matrix;
      if (!m || m.cols !== cols) {
        const drops = [], vel = [], seed = [];
        for (let i = 0; i < cols; i++) { drops.push(Math.random() * rows); vel.push((0.18 + Math.random() * 0.5) * speed); seed.push((Math.random() * 999) | 0); }
        m = this._state.matrix = { cols, drops, vel, seed };
      }
      return m;
    }
    seeds(n) {
      let s = this._state.seeds;
      if (!s || s.length !== n) {
        const rnd = mulberry32(1337 + n);
        s = this._state.seeds = [];
        for (let i = 0; i < n; i++) s.push({ bx: rnd(), by: rnd(), ax: 0.04 + rnd() * 0.07, ay: 0.04 + rnd() * 0.07, px: rnd() * TAU, py: rnd() * TAU, sp: 0.3 + rnd() * 0.5, x: 0, y: 0 });
      }
      const t = this._t;
      for (const p of s) { p.x = p.bx + p.ax * Math.sin(t * p.sp + p.px); p.y = p.by + p.ay * Math.cos(t * p.sp * 0.9 + p.py); }
      return s;
    }
    stars(n) {
      let s = this._state.stars;
      if (!s || s.length !== n) {
        const rnd = mulberry32(7 + n);
        s = this._state.stars = [];
        for (let i = 0; i < n; i++) {
          const b = rnd();
          const col = b > 0.72 ? "#bcd8ff" : (b < 0.2 ? "#ffe6c0" : "#ffffff");
          s.push({ a: rnd() * TAU, z: rnd(), b, col });
        }
      }
      return s;
    }

    render(t) {
      this._t = t;
      const def = EFFECTS[this.effect] || EFFECTS.ascii;
      // reset transient ctx state vector effects may set
      this.ctx.globalCompositeOperation = "source-over";
      this.ctx.filter = "none";
      def.paint(this, this.params);
    }
    frame(now) {
      if (this.staticFrame) return;
      if (!this.visible || this.paused) return;
      const fxDef = EFFECTS[this.effect];
      const cap = (fxDef && fxDef.fps) ? Math.min(this.fpsCap, fxDef.fps) : this.fpsCap;
      const minDelta = 1000 / cap;
      if (now - this._last < minDelta) return;
      this._last = now;
      if (!this._t0) this._t0 = now;
      this.render((now - this._t0) / 1000);
    }
  }

  /* ------------------------------ global driver --------------------------- */
  const all = [];
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      const c = e.target._dot;
      if (!c) return;
      c.visible = e.isIntersecting;
    });
  }, { rootMargin: "80px" });

  let running = false;
  function loop(now) {
    for (const c of all) c.frame(now);
    requestAnimationFrame(loop);
  }
  function register(el, opts) {
    const c = new DotCanvas(el, opts);
    el._dot = c; all.push(c); io.observe(el);
    if (!running) { running = true; requestAnimationFrame(loop); }
    return c;
  }

  global.DotEngine = {
    register, EFFECTS, EFFECT_ORDER, EFFECT_LABEL, SOURCES, brand, thermal, rgbStr,
    reduce: REDUCE,
  };
})(window);
