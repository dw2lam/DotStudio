/* ============================================================================
   DotStudio landing — page wiring
   Live GitHub release, scroll reveals, nav, hero effect cycling, the Lab.
   Rendering lives in engine.js (window.DotEngine).
============================================================================ */
(function () {
  "use strict";
  const E = window.DotEngine;
  const REPO = "dw2lam/dotstudio";
  const FALLBACK_VER = "1.0.0";

  /* ----------------------- live latest-release version -------------------- */
  function applyVersion(tag, url) {
    const v = String(tag || "").replace(/^v/i, "");
    if (!v) return;
    document.querySelectorAll("[data-latest-version]").forEach((el) => (el.textContent = v));
    document.querySelectorAll("[data-download-label]").forEach((el) => (el.textContent = "Download v" + v));
    document.querySelectorAll("[data-release-meta]").forEach((el) => (el.textContent = "Latest release · v" + v));
    if (url) document.querySelectorAll("[data-download-latest]").forEach((el) => (el.href = url));
  }
  fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((data) => {
      const dmg = (data.assets || []).find((a) => /\.dmg$/i.test(a.name)) ||
                  (data.assets || []).find((a) => /\.zip$/i.test(a.name));
      applyVersion(data.tag_name, dmg ? dmg.browser_download_url : data.html_url);
    })
    .catch(() => {/* keep static fallback */});

  /* ------------------------------ scroll reveal --------------------------- */
  const io = new IntersectionObserver(
    (entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }),
    { threshold: 0.1, rootMargin: "0px 0px -7% 0px" }
  );
  document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

  /* ----------------------------- nav elevate ------------------------------ */
  const nav = document.getElementById("nav");
  const onScroll = () => nav && nav.classList.toggle("scrolled", window.scrollY > 10);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* mobile nav toggle */
  const burger = document.querySelector(".nav-burger");
  if (burger) burger.addEventListener("click", () => document.body.classList.toggle("nav-open"));
  document.querySelectorAll(".nav-links a").forEach((a) =>
    a.addEventListener("click", () => document.body.classList.remove("nav-open")));

  /* --------------------- register every effect canvas --------------------- */
  document.querySelectorAll("[data-dot]").forEach((el) => {
    const params = el.dataset.params ? JSON.parse(el.dataset.params) : {};
    el._reg = E.register(el, { effect: el.dataset.effect, source: el.dataset.source, params });
  });

  /* ------------------------------ hero cycler ----------------------------- */
  const heroCanvas = document.getElementById("heroCanvas");
  if (heroCanvas && heroCanvas._reg) {
    const reg = heroCanvas._reg;
    const cycle = ["ascii", "halftone", "matrix", "thermal", "neon", "dither", "voronoi"];
    const chips = Array.from(document.querySelectorAll(".fx-chip"));
    const nameEl = document.querySelector("[data-hero-fx]");
    let i = 0, auto = true, timer = null;

    function setFx(name, fromUser) {
      reg.setEffect(name);
      if (nameEl) nameEl.textContent = E.EFFECT_LABEL[name] || name;
      chips.forEach((ch) => ch.classList.toggle("on", ch.dataset.fx === name));
      if (fromUser) { auto = false; document.querySelector(".hero-stage")?.classList.add("manual"); }
    }
    function tick() { if (!auto) return; i = (i + 1) % cycle.length; setFx(cycle[i]); }
    chips.forEach((ch) => ch.addEventListener("click", () => setFx(ch.dataset.fx, true)));
    setFx(cycle[0]);
    if (!E.reduce) timer = setInterval(tick, 3400);
  }

  /* -------------------------------- the lab ------------------------------- */
  const labCanvas = document.getElementById("labCanvas");
  if (labCanvas && labCanvas._reg) {
    const reg = labCanvas._reg;
    const labEl = document.getElementById("lab");
    const slots = {
      sliders: document.getElementById("labSliders"),
      effectName: document.querySelector("[data-lab-effect]"),
      readout: document.getElementById("labReadout"),
    };
    // per-effect tunable params shown as sliders (mirrors the app's controls)
    const SPECS = {
      ascii:    [["cell", "Cell Size", 6, 26, 1, 12], ["color", "Source Color", 0, 1, 1, 1]],
      halftone: [["cell", "Cell Size", 5, 30, 1, 10], ["angle", "Screen Angle", 0, 1.57, 0.01, 0.4]],
      dither:   [["cell", "Pixel Size", 1, 6, 0.5, 2.4], ["mono", "Monochrome", 0, 1, 1, 1], ["levels", "Levels", 2, 6, 1, 4]],
      dots:     [["cell", "Grid Size", 6, 36, 1, 13]],
      matrix:   [["cell", "Cell Size", 9, 26, 1, 14], ["speed", "Speed", 0.3, 2.4, 0.1, 1], ["reveal", "Reveal Source", 0, 1, 1, 1]],
      thermal:  [["gain", "Gain", 0.5, 1.8, 0.05, 1]],
      neon:     [["cell", "Detail", 3, 7, 0.5, 4], ["gain", "Glow", 1, 6, 0.5, 3]],
      voronoi:  [["count", "Density", 8, 60, 1, 26]],
      hex:      [["cell", "Cell Size", 10, 40, 1, 18]],
      gameboy:  [["dither", "Dither", 1, 5, 0.5, 2]],
      scanlines:[["cell", "Line Size", 1.5, 5, 0.5, 2.2]],
      vhs:      [["amount", "Amount", 0, 2, 0.05, 1]],
    };
    let cur = "ascii", params = {};

    function buildSliders(name) {
      const specs = SPECS[name] || [];
      params = {};
      slots.sliders.innerHTML = "";
      specs.forEach(([key, label, min, max, step, def]) => {
        params[key] = def;
        const isToggle = min === 0 && max === 1 && step === 1;
        const row = document.createElement("label");
        row.className = "lab-field" + (isToggle ? " is-toggle" : "");
        if (isToggle) {
          row.innerHTML = `<span class="lab-label">${label}</span>
            <span class="lab-toggle"><input type="checkbox" ${def ? "checked" : ""}><span class="tk"></span></span>`;
          row.querySelector("input").addEventListener("change", (ev) => {
            params[key] = ev.target.checked ? 1 : 0; reg.setParams({ ...params }); sync();
          });
        } else {
          row.innerHTML = `<span class="lab-label">${label}</span><b class="lab-val"></b>
            <input type="range" min="${min}" max="${max}" step="${step}" value="${def}">`;
          const out = row.querySelector(".lab-val"), inp = row.querySelector("input");
          const fmt = (v) => (step < 1 ? (+v).toFixed(2) : String(v | 0));
          out.textContent = fmt(def);
          inp.addEventListener("input", (ev) => {
            params[key] = +ev.target.value; out.textContent = fmt(ev.target.value);
            reg.setParams({ ...params }); sync();
          });
        }
        slots.sliders.appendChild(row);
      });
      reg.setParams({ ...params });
      sync();
    }
    function sync() {
      if (slots.effectName) slots.effectName.textContent = E.EFFECT_LABEL[cur] || cur;
      if (slots.readout) {
        const parts = Object.entries(params).map(([k, v]) => `${k}:${(+v).toFixed(step(k) < 1 ? 2 : 0)}`);
        slots.readout.textContent = `fx ${cur} · src ${labSource} · ${parts.join("  ")}`;
      }
    }
    function step(key) {
      const s = (SPECS[cur] || []).find((x) => x[0] === key);
      return s ? s[4] : 1;
    }

    // effect picker (chips)
    let labSource = "aurora";
    document.querySelectorAll(".lab-fx").forEach((b) =>
      b.addEventListener("click", () => {
        cur = b.dataset.fx; reg.setEffect(cur);
        document.querySelectorAll(".lab-fx").forEach((x) => x.classList.toggle("on", x === b));
        buildSliders(cur);
      }));
    // source picker
    document.querySelectorAll(".lab-src").forEach((b) =>
      b.addEventListener("click", () => {
        labSource = b.dataset.src; reg.setSource(labSource);
        document.querySelectorAll(".lab-src").forEach((x) => x.classList.toggle("on", x === b));
        sync();
      }));

    buildSliders("ascii");
  }

  /* ---------------------- footer year + smooth anchors -------------------- */
  const yr = document.querySelector("[data-year]");
  if (yr) yr.textContent = new Date().getFullYear();
})();
