// Keel stats dashboard — fetches the anonymous aggregate counters from
// /v1/stats (same origin behind KeelStatsSite's CloudFront, so no CORS) and
// renders them as bespoke inline SVG. No charting dependency, nothing loaded
// from a CDN. Every color comes from tokens.css via getComputedStyle, so
// rebranding and dark mode never touch this file.
//
// Merged from Orthanc's stats.js and odvpn's usage.js, which were
// near-duplicates; where they differed, each one's better half is kept and
// the trial cohort — which neither had — is added as a third lane.

const REDUCED_MOTION = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const SVG_NS = "http://www.w3.org/2000/svg";

// Last-rendered series, kept so a window resize can redraw the SVGs crisply.
let latest = null;

// ─── Utilities ──────────────────────────────────────────────────────────────

function token(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function formatInt(n) {
  return n.toLocaleString("en-US");
}

function svgEl(tag, attrs = {}, text) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  if (text != null) node.textContent = text;
  return node;
}

// Count up to the target for the hero figures. Short, eased, skipped entirely
// under prefers-reduced-motion.
function animateCount(node, target) {
  if (REDUCED_MOTION || target === 0) {
    node.textContent = formatInt(target);
    return;
  }
  const duration = 900;
  let start = null;
  function step(ts) {
    if (start === null) start = ts;
    const t = Math.min((ts - start) / duration, 1);
    const eased = 1 - Math.pow(1 - t, 3); // easeOutCubic
    node.textContent = formatInt(Math.round(target * eased));
    if (t < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

// Local development: `?api=https://…` points the page at a deployed backend
// (odvpn's affordance, kept — it is how you check a stack before DNS exists).
const API_BASE = (() => {
  const override = new URLSearchParams(window.location.search).get("api");
  return override ? override.replace(/\/$/, "") : "";
})();

// ─── Line chart (DAU) ───────────────────────────────────────────────────────

// One or more series over the same points: `points` carry a `label` plus one
// numeric field per series, `opts.series` names the fields. Cohorts are lanes
// on one drawing, not separate charts.
function renderLine(figure, points, opts = {}) {
  const empty = figure.querySelector(".chart-empty");
  figure.querySelector("svg")?.remove();
  if (!points.length) {
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  const series = opts.series ?? [{ key: "count", color: "--accent", area: true, dot: true }];
  const W = Math.max(figure.clientWidth, 320);
  const H = 220;
  const pad = { top: 16, right: 12, bottom: 28, left: 44 };
  const innerW = W - pad.left - pad.right;
  const innerH = H - pad.top - pad.bottom;
  const valueOf = (p, s) => p[s.key] ?? 0;
  const max = Math.max(1, ...points.flatMap((p) => series.map((s) => valueOf(p, s))));

  const x = (i) =>
    pad.left + (points.length === 1 ? innerW / 2 : (innerW * i) / (points.length - 1));
  const y = (v) => pad.top + innerH - (innerH * v) / max;

  const svg = svgEl("svg", {
    viewBox: `0 0 ${W} ${H}`,
    width: "100%",
    height: H,
    role: "img",
    preserveAspectRatio: "none",
  });
  svg.appendChild(svgEl("title", {}, opts.title ?? "Daily active devices"));

  const hairline = token("--hairline");
  const text2 = token("--text-2");
  const mono = token("--font-mono");

  // Horizontal gridlines + y labels at 0, mid, max.
  for (const frac of [0, 0.5, 1]) {
    const v = Math.round(max * frac);
    const gy = y(v);
    svg.appendChild(svgEl("line", {
      x1: pad.left, y1: gy, x2: W - pad.right, y2: gy,
      stroke: hairline, "stroke-width": 1,
    }));
    svg.appendChild(svgEl("text", {
      x: pad.left - 8, y: gy + 4, "text-anchor": "end",
      fill: text2, "font-size": 11, "font-family": mono,
    }, formatInt(v)));
  }

  const defs = svgEl("defs");
  svg.appendChild(defs);
  const last = points.length - 1;

  series.forEach((s, si) => {
    const stroke = token(s.color);
    const linePts = points.map((p, i) => `${x(i)},${y(valueOf(p, s))}`).join(" ");

    // Area fill under the line — only the lit series gets one, so lanes don't
    // muddy each other where they cross.
    if (s.area) {
      const gradId = `${figure.id || "chart"}-area-${si}`;
      const grad = svgEl("linearGradient", { id: gradId, x1: 0, y1: 0, x2: 0, y2: 1 });
      grad.appendChild(svgEl("stop", { offset: "0%", "stop-color": stroke, "stop-opacity": 0.28 }));
      grad.appendChild(svgEl("stop", { offset: "100%", "stop-color": stroke, "stop-opacity": 0 }));
      defs.appendChild(grad);
      svg.appendChild(svgEl("polygon", {
        points: `${pad.left},${y(0)} ${linePts} ${x(last)},${y(0)}`,
        fill: `url(#${gradId})`,
      }));
    }

    const line = svgEl("polyline", {
      points: linePts, fill: "none", stroke,
      "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
    });
    svg.appendChild(line);

    // Draw-on animation (skipped under reduced motion).
    if (!REDUCED_MOTION && line.getTotalLength) {
      const len = line.getTotalLength();
      if (len) {
        line.style.strokeDasharray = String(len);
        line.style.strokeDashoffset = String(len);
        line.style.transition = "stroke-dashoffset 1s ease-out";
        requestAnimationFrame(() => { line.style.strokeDashoffset = "0"; });
      }
    }

    // The final point of the lit series gets the dot.
    if (s.dot) {
      svg.appendChild(svgEl("circle", {
        cx: x(last), cy: y(valueOf(points[last], s)), r: 4,
        fill: stroke, stroke: token("--bg"), "stroke-width": 1.5,
      }));
    }
  });

  // Sparse x labels: first, middle, last.
  const labelIdx =
    points.length <= 2 ? points.map((_, i) => i) : [0, Math.floor(last / 2), last];
  for (const i of labelIdx) {
    svg.appendChild(svgEl("text", {
      x: x(i), y: H - 8,
      "text-anchor": i === 0 ? "start" : i === last ? "end" : "middle",
      fill: text2, "font-size": 11, "font-family": mono,
    }, points[i].label));
  }

  figure.appendChild(svg);
}

// ─── Column chart (MAU) ─────────────────────────────────────────────────────

// `opts.stack` turns each column into cohort segments, bottom-up in the order
// given. The point of the MAU chart is still the monthly total, and a stack
// keeps that readable as the column height while showing the split inside it.
function renderColumns(figure, points, opts = {}) {
  const empty = figure.querySelector(".chart-empty");
  figure.querySelector("svg")?.remove();
  if (!points.length) {
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  const stack = opts.stack ?? null;
  const totalOf = (p) => (stack ? stack.reduce((s, seg) => s + (p[seg.key] ?? 0), 0) : p.count);

  const W = Math.max(figure.clientWidth, 300);
  const H = 220;
  const pad = { top: 16, right: 8, bottom: 28, left: 44 };
  const innerW = W - pad.left - pad.right;
  const innerH = H - pad.top - pad.bottom;
  const max = Math.max(...points.map(totalOf), 1);
  const gap = 8;
  const bw = Math.max((innerW - gap * (points.length - 1)) / points.length, 2);

  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, width: "100%", height: H, role: "img" });
  svg.appendChild(svgEl("title", {}, opts.title ?? "Monthly active devices"));
  const accent = token("--accent");
  const muted = token("--muted");
  const text2 = token("--text-2");
  const hairline = token("--hairline");
  const mono = token("--font-mono");

  svg.appendChild(svgEl("line", {
    x1: pad.left, y1: pad.top + innerH, x2: W - pad.right, y2: pad.top + innerH,
    stroke: hairline, "stroke-width": 1,
  }));

  points.forEach((p, i) => {
    const bx = pad.left + i * (bw + gap);
    const isLast = i === points.length - 1;
    const baseline = pad.top + innerH;

    // One rect per stack segment, or a single rect for the plain series.
    const segments = stack
      ? stack.map((seg) => ({ value: p[seg.key] ?? 0, fill: token(seg.color) }))
      : [{ value: p.count, fill: isLast ? accent : muted }];

    let bottom = baseline;
    segments.forEach((seg, si) => {
      const h = (innerH * seg.value) / max;
      const by = bottom - h;
      // A zero-height rect draws nothing but a stray rounded cap; skip it so an
      // all-free month has no ghost paid sliver on top.
      if (h > 0) {
        const rect = svgEl("rect", {
          x: bx, y: REDUCED_MOTION ? by : bottom,
          width: bw, height: REDUCED_MOTION ? h : 0, rx: 3,
          fill: seg.fill,
        });
        svg.appendChild(rect);
        if (!REDUCED_MOTION) {
          rect.style.transition = "y 0.7s ease-out, height 0.7s ease-out";
          rect.style.transitionDelay = `${i * 30 + si * 40}ms`;
          requestAnimationFrame(() => {
            rect.setAttribute("y", by);
            rect.setAttribute("height", h);
          });
        }
      }
      bottom = by;
    });

    // Label every other month when crowded, always the last.
    const showLabel = points.length <= 6 || i % 2 === 0 || isLast;
    if (showLabel) {
      svg.appendChild(svgEl("text", {
        x: bx + bw / 2, y: H - 8, "text-anchor": "middle",
        fill: text2, "font-size": 10.5, "font-family": mono,
      }, p.label.slice(2))); // "26-08" — the year prefix is noise at this width
    }
  });

  figure.appendChild(svg);
}

// ─── Horizontal bars (versions, OS, platforms, dimensions) ──────────────────

// Rows are { label, count }. `opts.lead` lights the first row with the accent,
// which reads as "the leader" only when rows are ranked by count — dimension
// panels are in declared bucket order, so they pass `lead: false` and stay
// uniformly muted.
function renderBars(figure, rows, opts = {}) {
  const lead = opts.lead ?? true;
  const empty = figure.querySelector(".chart-empty");
  figure.querySelectorAll(".vbar").forEach((n) => n.remove());
  if (!rows.length) {
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  const total = rows.reduce((s, v) => s + v.count, 0) || 1;
  rows.forEach((v, i) => {
    const pct = (v.count / total) * 100;
    const row = document.createElement("div");
    row.className = lead && i === 0 ? "vbar vbar-lead" : "vbar";

    const name = document.createElement("span");
    name.className = "vbar-name";
    name.textContent = v.label;

    const track = document.createElement("span");
    track.className = "vbar-track";
    const fill = document.createElement("span");
    fill.className = "vbar-fill";
    fill.style.width = REDUCED_MOTION ? `${pct}%` : "0%";
    track.appendChild(fill);

    const val = document.createElement("span");
    val.className = "vbar-val";
    val.textContent = `${formatInt(v.count)} · ${Math.round(pct)}%`;

    row.append(name, track, val);
    figure.appendChild(row);

    if (!REDUCED_MOTION) {
      requestAnimationFrame(() => {
        fill.style.transitionDelay = `${i * 40}ms`;
        fill.style.width = `${pct}%`;
      });
    }
  });
}

// ─── Cohorts ────────────────────────────────────────────────────────────────

// Up to three lanes, drawn bottom-up. Paid is last — the lit one, with the area
// and the dot; free and trial sit quietly underneath. A cohort is dropped from
// the drawing (and, via syncLegend, from the legend) whenever every point in the
// current window is zero, so an app that never uses one — no trials, say — shows
// two lanes instead of a flat line pinned to the axis. It's a pure render-time
// call with no config, and self-correcting: the lane reappears on its own the
// first day a real value lands.
function drawnCohorts(points, defs) {
  return defs.filter((c) => points.some((p) => (p[c.key] ?? 0) > 0));
}

function cohortSeries(points) {
  return drawnCohorts(points, [
    { key: "free", color: "--cohort-free" },
    { key: "trial", color: "--cohort-trial" },
    { key: "paid", color: "--cohort-paid", area: true, dot: true },
  ]);
}

function cohortStack(points) {
  return drawnCohorts(points, [
    { key: "free", color: "--cohort-free" },
    { key: "trial", color: "--cohort-trial" },
    { key: "paid", color: "--cohort-paid" },
  ]);
}

// Show/hide the legend entries to match the lanes actually drawn.
function syncLegend(figureId, lanes) {
  const legend = document.querySelector(`[data-legend-for="${figureId}"]`);
  if (!legend) return;
  const drawn = new Set(lanes.map((l) => l.key));
  legend.querySelectorAll("[data-cohort]").forEach((n) => {
    n.hidden = !drawn.has(n.dataset.cohort);
  });
  legend.querySelectorAll(".swatch[data-token]").forEach((n) => {
    n.style.background = token(n.dataset.token);
  });
}

// ─── Page assembly ──────────────────────────────────────────────────────────

// Every figure falls back to its empty message, never a stale or half number.
function resetFigures(message) {
  document.querySelectorAll(".chart-empty").forEach((n) => {
    if (message) n.textContent = message;
    n.hidden = false;
  });
  for (const id of ["installs", "conversions", "dau-latest", "mau-latest"]) {
    const node = document.getElementById(id);
    if (node) node.textContent = "—";
  }
}

// One bar panel per app-declared dimension, created on the fly: the page
// cannot know an app's dimensions ahead of time, and a config change should
// appear here without an HTML edit. Buckets arrive in declared order and are
// rendered exactly as sent (never re-sorted — the axis is ordered, not ranked).
function renderDimensions(container, dimensions) {
  container.textContent = "";
  for (const [name, buckets] of Object.entries(dimensions ?? {})) {
    if (!buckets.length) continue;
    const card = document.createElement("section");
    card.className = "card";
    const title = document.createElement("h2");
    title.textContent = name;
    const sub = document.createElement("p");
    sub.className = "card-sub";
    sub.textContent = "This month, by bucket. Bucketed on the device — raw values never leave it.";
    const figure = document.createElement("figure");
    figure.style.margin = "0";
    card.append(title, sub, figure);
    container.appendChild(card);
    renderBars(figure, buckets.map((b) => ({ label: b.bucket, count: b.count })), { lead: false });
  }
}

async function load() {
  let data;
  try {
    const res = await fetch(API_BASE + "/v1/stats", { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    data = await res.json();
  } catch {
    resetFigures("Usage numbers are unavailable right now. Try again shortly.");
    return;
  }

  animateCount(document.getElementById("installs"), data.installs ?? 0);
  animateCount(document.getElementById("conversions"), data.conversions ?? 0);

  // Cohort points carry every lane explicitly (the backend zero-fills), so
  // asymmetric data draws no holes.
  const dau = (data.dauByState ?? []).map((p) => ({
    label: p.date.slice(5), // MM-DD
    free: p.free ?? 0,
    trial: p.trial ?? 0,
    paid: p.paid ?? 0,
  }));
  const mau = (data.mauByState ?? []).map((p) => ({
    label: p.month,
    free: p.free ?? 0,
    trial: p.trial ?? 0,
    paid: p.paid ?? 0,
  }));
  latest = { dau, mau };

  const dauLanes = cohortSeries(dau);
  const mauStack = cohortStack(mau);
  syncLegend("chart-dau", dauLanes);
  syncLegend("chart-mau", mauStack);
  renderLine(document.getElementById("chart-dau"), dau, { series: dauLanes });
  renderColumns(document.getElementById("chart-mau"), mau, { stack: mauStack });

  const dauLast = dau.at(-1);
  document.getElementById("dau-latest").textContent = dauLast
    ? formatInt(dauLast.free + dauLast.trial + dauLast.paid)
    : "—";
  const mauLast = (data.mau ?? []).at(-1);
  document.getElementById("mau-latest").textContent = mauLast
    ? formatInt(mauLast.count)
    : "—";

  renderBars(
    document.getElementById("chart-versions"),
    (data.versions ?? []).map((v) => ({ label: v.version, count: v.count })));
  renderBars(
    document.getElementById("chart-os"),
    (data.osVersions ?? []).map((o) => ({ label: o.osVersion, count: o.count })));
  renderBars(
    document.getElementById("chart-platforms"),
    (data.platforms ?? []).map((p) => ({ label: p.platform, count: p.count })));

  renderDimensions(document.getElementById("dimensions"), data.dimensions);

  if (data.generatedAt) {
    const gen = document.getElementById("generated");
    gen.textContent =
      `Last updated ${new Date(data.generatedAt).toUTCString()}. Cached for up to five minutes.`;
    gen.hidden = false;
  }
}

// Redraw the SVG charts on resize (debounced) so they stay crisp. The bar
// panels are plain CSS-width divs and reflow on their own.
let resizeTimer;
window.addEventListener("resize", () => {
  if (!latest) return;
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    renderLine(document.getElementById("chart-dau"), latest.dau, {
      series: cohortSeries(latest.dau),
    });
    renderColumns(document.getElementById("chart-mau"), latest.mau, {
      stack: cohortStack(latest.mau),
    });
  }, 150);
});

load();
