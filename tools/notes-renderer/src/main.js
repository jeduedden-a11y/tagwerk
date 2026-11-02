// Renders Obsidian notes inside the Tagwerk app (WKWebView, offline).
// Bundled by build.mjs into App/Resources/notes.js; the app calls window.TW.render(payload).
import MarkdownIt from "markdown-it";
import katexModule from "@vscode/markdown-it-katex";
import footnote from "markdown-it-footnote";
import mark from "markdown-it-mark";

const IMAGE = new Set(["svg", "png", "jpg", "jpeg", "gif", "webp"]);
const OBSIDIAN_ONLY = {
  dataview: "Dataview-Abfrage",
  dataviewjs: "DataviewJS",
  chart: "Diagramm (Charts)",
  smiles: "Strukturformel (SMILES)",
  tracker: "Tracker",
  mermaid: "Mermaid-Diagramm",
  query: "Suchabfrage",
  "meta-bind": "Meta Bind",
  tikz: "TikZ",
  desmos: "Desmos",
  "desmos-graph": "Desmos",
};

let currentPath = "";

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function splitOnce(s, sep) {
  const i = s.indexOf(sep);
  return i < 0 ? [s, null] : [s.slice(0, i), s.slice(i + 1)];
}

function display(target) {
  const [file, heading] = splitOnce(target, "#");
  const base = file.split("/").pop().replace(/\.md$/i, "");
  if (!base && heading) return heading.replace(/^\^/, "");
  return heading ? `${base} › ${heading.replace(/^\^/, "")}` : base;
}

const openURL = (target) => `twnote://open?t=${encodeURIComponent(target)}`;
// Same origin as the page (twnote://app), so the renderer may also read an embedded SVG's source.
const embedURL = (target) => `twnote://app/embed?t=${encodeURIComponent(target)}&from=${encodeURIComponent(currentPath)}`;

/** Width from Obsidian's size suffix: "440" or "440x300". */
function widthOf(opt) {
  const m = opt && /^\s*(\d+)(x\d+)?\s*$/.exec(opt);
  return m ? parseInt(m[1], 10) : null;
}

function figure(file, alt, width) {
  const ext = file.split(".").pop().toLowerCase();
  const kind = ext === "svg" ? "svg" : "raster";
  const size = width ? ` style="max-width:${width + 24}px"` : "";
  return `<span class="figure" data-kind="${kind}" data-tone="pending"${size}><img src="${embedURL(file)}" alt="${esc(alt)}" loading="lazy"></span>`;
}

function wikilinks(md) {
  md.inline.ruler.before("link", "wikilink", (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    const embed = src.charCodeAt(pos) === 0x21;
    if (embed) pos++;
    if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b) return false;
    const end = src.indexOf("]]", pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || inner.includes("\n")) return false;
    if (!silent) {
      const t = state.push(embed ? "wikiembed" : "wikilink", "", 0);
      t.content = inner.replace(/\\\|/g, "|");
    }
    state.pos = end + 2;
    return true;
  });
  md.renderer.rules.wikilink = (tokens, idx) => {
    const [target, alias] = splitOnce(tokens[idx].content, "|");
    return `<a class="wikilink" href="${openURL(target.trim())}">${esc(alias ?? display(target.trim()))}</a>`;
  };
  md.renderer.rules.wikiembed = (tokens, idx) => {
    const [targetRaw, opt] = splitOnce(tokens[idx].content, "|");
    const target = targetRaw.trim();
    const file = splitOnce(target, "#")[0];
    const ext = file.includes(".") ? file.split(".").pop().toLowerCase() : "md";
    if (IMAGE.has(ext)) {
      const width = widthOf(opt);
      return figure(file, opt && width === null ? opt : file.split("/").pop(), width);
    }
    if (ext === "html" || ext === "htm") {
      return `<iframe class="embed-html" sandbox="allow-scripts" src="${embedURL(file)}"></iframe>`;
    }
    return `<a class="embed-note" href="${openURL(target)}"><span class="embed-label">Eingebettet</span> ${esc(display(target))}</a>`;
  };
}

const md = new MarkdownIt({ html: true, linkify: true, breaks: true, typographer: false });
const katexPlugin = typeof katexModule === "function" ? katexModule : katexModule.default;
md.use(katexPlugin, { throwOnError: false, errorColor: "#e5534b", strict: "ignore", output: "html", trust: false });
md.use(footnote);
md.use(mark);
md.use(wikilinks);

const defaultImage = md.renderer.rules.image;
md.renderer.rules.image = (tokens, idx, options, env, self) => {
  const t = tokens[idx];
  const src = t.attrGet("src") || "";
  if (!/^[a-z][a-z0-9+.-]*:/i.test(src)) {
    let target = src;
    try {
      target = decodeURI(src);
    } catch {
      // keep as written
    }
    const file = target.split(/[?#]/)[0];
    const ext = file.includes(".") ? file.split(".").pop().toLowerCase() : "";
    if (IMAGE.has(ext)) {
      const [alt, opt] = splitOnce(t.content || "", "|");
      return figure(file, alt || file.split("/").pop(), widthOf(opt));
    }
  }
  return defaultImage(tokens, idx, options, env, self);
};

const defaultFence = md.renderer.rules.fence;
md.renderer.rules.fence = (tokens, idx, options, env, self) => {
  const info = (tokens[idx].info || "").trim().split(/\s+/)[0].toLowerCase();
  if (OBSIDIAN_ONLY[info]) {
    return `<div class="obsidian-only"><span class="label">Nur in Obsidian</span> ${esc(OBSIDIAN_ONLY[info])}</div>`;
  }
  return defaultFence(tokens, idx, options, env, self);
};

function slug(text) {
  return text.trim().toLowerCase().replace(/\s+/g, "-").replace(/[^\p{L}\p{N}_-]/gu, "");
}

const CALLOUT_ALIAS = {
  summary: "abstract", tldr: "abstract", hint: "tip", check: "success", done: "success", help: "question", faq: "question",
  caution: "warning", attention: "warning", fail: "failure", missing: "failure", error: "danger", cite: "quote",
};
const CALLOUT_TITLE = {
  note: "Notiz", abstract: "Zusammenfassung", info: "Info", todo: "Aufgabe", tip: "Tipp", success: "Erledigt", question: "Frage",
  warning: "Achtung", failure: "Fehlschlag", danger: "Gefahr", bug: "Fehler", example: "Beispiel", quote: "Zitat", important: "Wichtig",
};

function callouts(root) {
  for (const bq of [...root.querySelectorAll("blockquote")]) {
    const first = bq.firstElementChild;
    if (!first || first.tagName !== "P") continue;
    const m = /^\s*\[!([A-Za-z-]+)\]([+-]?)[ \t]*/.exec(first.innerHTML);
    if (!m) continue;
    const raw = m[1].toLowerCase();
    const type = CALLOUT_ALIAS[raw] ?? raw;
    const fold = m[2];
    let rest = first.innerHTML.slice(m[0].length);
    const br = rest.search(/<br\s*\/?>/i);
    const titleHtml = (br >= 0 ? rest.slice(0, br) : rest).trim() || esc(CALLOUT_TITLE[type] ?? raw.charAt(0).toUpperCase() + raw.slice(1));
    rest = br >= 0 ? rest.slice(br).replace(/^<br\s*\/?>\s*/i, "") : "";

    const box = document.createElement(fold ? "details" : "div");
    box.className = "callout";
    box.dataset.callout = type;
    if (fold === "+") box.setAttribute("open", "");
    const title = document.createElement(fold ? "summary" : "div");
    title.className = "callout-title";
    title.innerHTML = titleHtml;
    const content = document.createElement("div");
    content.className = "callout-content";
    if (rest.trim()) {
      const p = document.createElement("p");
      p.innerHTML = rest;
      content.appendChild(p);
    }
    first.remove();
    while (bq.firstChild) content.appendChild(bq.firstChild);
    box.appendChild(title);
    if (content.childNodes.length) box.appendChild(content);
    bq.replaceWith(box);
  }
}

function tasks(root) {
  for (const li of root.querySelectorAll("li")) {
    const node = li.firstChild?.nodeType === 3 ? li.firstChild : li.firstElementChild?.tagName === "P" ? li.firstElementChild.firstChild : null;
    if (!node || node.nodeType !== 3) continue;
    const m = /^\[([ xX])\]\s/.exec(node.textContent);
    if (!m) continue;
    node.textContent = node.textContent.slice(m[0].length);
    const box = document.createElement("span");
    box.className = m[1] === " " ? "task" : "task done";
    li.classList.add("task-item");
    li.insertBefore(box, li.firstChild);
  }
}

// --- Figures: every image gets the backdrop its own ink needs ------------------------------------
// The vault's SVGs are drawn either for Obsidian's dark theme (white text, light lines, no background)
// or, in older ones, for a light page (dark text). Choosing the backdrop per figure, independent of the
// app's appearance, keeps both kinds legible in light mode, dark mode and the PDF export.

const PANEL_DARK = 0.0123; // relative luminance of #1e1e1e
const PANEL_LIGHT = 1; // #ffffff
const toneCache = new Map();

function channel(c) {
  const v = c / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}
const luminance = ({ r, g, b }) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
const contrast = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);

/** Computed colours come back as rgb()/rgba(), with commas or spaces; anything else (none, url(...)) is null. */
function parseColor(value) {
  const m = /^rgba?\((.*)\)$/i.exec(String(value || "").trim());
  if (!m) return null;
  const parts = m[1].split(/[\s,/]+/).filter(Boolean);
  if (parts.length < 3) return null;
  const num = (s, scale) => (s.endsWith("%") ? (parseFloat(s) / 100) * scale : parseFloat(s));
  const [r, g, b] = parts.slice(0, 3).map((s) => num(s, 255));
  const a = parts.length > 3 ? num(parts[3], 1) : 1;
  return [r, g, b, a].some((n) => Number.isNaN(n)) ? null : { r, g, b, a };
}

/** The backdrop on which the weighted ink reads better: dark panel ("light-ink") or light panel ("dark-ink"). */
function backdropFor(ink) {
  let total = 0;
  let onDark = 0;
  let onLight = 0;
  for (const { lum, weight } of ink) {
    total += weight;
    onDark += weight * Math.min(contrast(lum, PANEL_DARK), 7);
    onLight += weight * Math.min(contrast(lum, PANEL_LIGHT), 7);
  }
  if (!total) return null;
  // Ties go to the dark panel: that is what the vault's figures are drawn for.
  return onDark >= onLight * 0.95 ? "light-ink" : "dark-ink";
}

const opacityOf = (cs) => parseFloat(cs.opacity || "1");
const visible = (cs) => cs.display !== "none" && cs.visibility !== "hidden" && opacityOf(cs) > 0.05;

function paintOf(cs, which) {
  const c = parseColor(which === "fill" ? cs.fill : cs.stroke);
  if (!c) return null;
  const alpha = c.a * parseFloat((which === "fill" ? cs.fillOpacity : cs.strokeOpacity) || "1");
  return alpha >= 0.3 ? c : null;
}

/**
 * Classifies an SVG by what it actually paints: the source is laid out invisibly in a shadow root
 * (its own <style> stays inside), so classes, inheritance and the default black fill all count.
 * Returns "own" (opaque background of its own), "light-ink", "dark-ink" or null.
 */
function svgTone(text) {
  const doc = new DOMParser().parseFromString(text, "image/svg+xml");
  const src = doc.documentElement;
  if (!src || src.localName !== "svg" || doc.getElementsByTagName("parsererror").length) return null;
  for (const el of [...src.querySelectorAll("script, foreignObject")]) el.remove();
  for (const el of [src, ...src.querySelectorAll("*")]) {
    for (const a of [...el.attributes]) if (/^on/i.test(a.name)) el.removeAttribute(a.name);
  }
  const host = document.createElement("div");
  // Like an <img>: black is the default colour, nothing inherited from the page. Kept off-screen and
  // transparent rather than visibility:hidden, which the SVG's elements would inherit.
  host.style.cssText = "position:absolute;left:-30000px;top:0;width:1000px;height:800px;overflow:hidden;opacity:0;pointer-events:none;contain:strict;color:#000;fill:#000;stroke:none;font:16px sans-serif";
  const svg = document.importNode(src, true);
  host.attachShadow({ mode: "open" }).appendChild(svg);
  document.body.appendChild(host);
  try {
    const rootBg = parseColor(getComputedStyle(svg).backgroundColor);
    if (rootBg && rootBg.a > 0.9) return "own";
    const vb = svg.viewBox?.baseVal;
    const W = vb && vb.width ? vb.width : svg.width?.baseVal?.value || 0;
    const H = vb && vb.height ? vb.height : svg.height?.baseVal?.value || 0;
    if (W > 0 && H > 0) {
      // A background is a large opaque rectangle near the top of the tree.
      const near = [...svg.querySelectorAll(":scope > rect, :scope > g > rect")].slice(0, 24);
      for (const r of near) {
        let b;
        try {
          b = r.getBBox();
        } catch {
          continue;
        }
        if (b.width < 0.9 * W || b.height < 0.9 * H) continue;
        const cs = getComputedStyle(r);
        const fill = paintOf(cs, "fill");
        if (fill && fill.a * opacityOf(cs) > 0.9) return "own";
      }
    }
    const text = [];
    for (const el of [...svg.querySelectorAll("text, tspan, textPath")].slice(0, 600)) {
      let own = "";
      for (const n of el.childNodes) if (n.nodeType === 3) own += n.textContent;
      own = own.trim();
      if (!own || el.closest("defs, symbol, marker, pattern, mask, clipPath")) continue;
      const cs = getComputedStyle(el);
      if (!visible(cs)) continue;
      const paint = paintOf(cs, "fill") || paintOf(cs, "stroke");
      if (paint) text.push({ lum: luminance(paint), weight: Math.min(own.length, 60) });
    }
    const lines = [];
    const fills = [];
    for (const el of [...svg.querySelectorAll("line, polyline, path, circle, ellipse, rect, polygon")].slice(0, 1500)) {
      if (el.closest("defs, symbol, marker, pattern, mask, clipPath")) continue;
      const cs = getComputedStyle(el);
      if (!visible(cs)) continue;
      const stroke = paintOf(cs, "stroke");
      if (stroke) lines.push({ lum: luminance(stroke), weight: 3 });
      else {
        const fill = paintOf(cs, "fill");
        if (fill) fills.push({ lum: luminance(fill), weight: 1 });
      }
    }
    // Text decides first; lines count at most half as much, filled shapes only when nothing else is there.
    const textWeight = text.reduce((s, x) => s + x.weight, 0);
    const lineWeight = lines.reduce((s, x) => s + x.weight, 0);
    const scale = textWeight && lineWeight > textWeight / 2 ? textWeight / 2 / lineWeight : 1;
    const ink = [...text, ...lines.map((x) => ({ lum: x.lum, weight: x.weight * scale }))];
    return backdropFor(ink.length ? ink : fills);
  } finally {
    host.remove();
  }
}

/** Raster images: opaque ones keep their own background, transparent ones are judged by their visible pixels. */
function rasterTone(img) {
  const w = img.naturalWidth;
  const h = img.naturalHeight;
  if (!w || !h) return null;
  const scale = Math.min(1, 64 / Math.max(w, h));
  const cw = Math.max(1, Math.round(w * scale));
  const ch = Math.max(1, Math.round(h * scale));
  const canvas = document.createElement("canvas");
  canvas.width = cw;
  canvas.height = ch;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, cw, ch);
  const d = ctx.getImageData(0, 0, cw, ch).data;
  let solid = 0;
  const buckets = new Map();
  for (let i = 0; i < d.length; i += 4) {
    const a = d[i + 3] / 255;
    if (a > 0.9) solid++;
    if (a < 0.3) continue;
    const k = Math.round(luminance({ r: d[i], g: d[i + 1], b: d[i + 2] }) * 40);
    buckets.set(k, (buckets.get(k) || 0) + a);
  }
  if (solid / (cw * ch) > 0.97) return "own";
  return backdropFor([...buckets].map(([k, weight]) => ({ lum: k / 40, weight })));
}

function classify(fig) {
  const img = fig.querySelector("img");
  if (!img) return;
  // A result always wins; the timer only makes sure a figure is never hidden for long.
  const apply = (tone) => {
    if (fig.dataset.tone === "missing") return;
    if (tone) fig.dataset.tone = tone;
    else if (fig.dataset.tone === "pending") fig.dataset.tone = "unknown";
  };
  setTimeout(() => apply(null), 2500);
  const key = img.getAttribute("src");
  if (toneCache.has(key)) return apply(toneCache.get(key));
  const remember = (tone) => {
    if (tone) toneCache.set(key, tone);
    apply(tone);
  };
  if (fig.dataset.kind === "svg") {
    fetch(key)
      .then((r) => r.text())
      .then(svgTone)
      .catch(() => null)
      .then(remember);
    return;
  }
  const run = () => {
    let tone = null;
    try {
      tone = rasterTone(img);
    } catch {
      tone = null;
    }
    remember(tone);
  };
  if (img.complete && img.naturalWidth) run();
  else img.addEventListener("load", run, { once: true });
}

function decorate(root) {
  callouts(root);
  tasks(root);
  for (const h of root.querySelectorAll("h1,h2,h3,h4,h5,h6")) h.id = slug(h.textContent);
  for (const t of root.querySelectorAll("table")) {
    const wrap = document.createElement("div");
    wrap.className = "table-wrap";
    t.replaceWith(wrap);
    wrap.appendChild(t);
  }
  for (const a of root.querySelectorAll("a[href^='http']")) a.classList.add("external");
  for (const fig of root.querySelectorAll(".figure")) {
    const img = fig.querySelector("img");
    img.addEventListener("error", () => {
      const s = document.createElement("span");
      s.className = "missing";
      s.textContent = `Abbildung fehlt: ${img.alt}`;
      img.replaceWith(s);
      fig.dataset.tone = "missing";
    });
    classify(fig);
  }
}

function render(payload) {
  currentPath = payload.path || "";
  const source = String(payload.md || "").replace(/%%[\s\S]*?%%/g, "");
  const tags = (payload.tags || []).map((t) => `<span class="tag">#${esc(t)}</span>`).join("");
  const head = `<header><h1 class="note-title">${esc(payload.title || "")}</h1>${payload.folder ? `<div class="folder">${esc(payload.folder)}</div>` : ""}${tags ? `<div class="tags">${tags}</div>` : ""}</header>`;
  const article = document.getElementById("note");
  article.innerHTML = head + md.render(source);
  // A first heading that repeats the title is dropped.
  const firstH1 = article.querySelector("h1:not(.note-title)");
  if (firstH1 && firstH1.textContent.trim() === (payload.title || "").trim() && firstH1 === article.children[1]) firstH1.remove();
  decorate(article);
  window.scrollTo(0, 0);
  if (payload.heading) scrollToHeading(payload.heading);
  return article.textContent.length;
}

function scrollToHeading(h) {
  const id = slug(String(h).replace(/^#/, ""));
  const el = document.getElementById(id) || [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].find((x) => slug(x.textContent).startsWith(id));
  if (el) el.scrollIntoView({ block: "start" });
}

window.TW = { render, scrollToHeading, svgTone };
