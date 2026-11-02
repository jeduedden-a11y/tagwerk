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
const embedURL = (target) => `twnote://embed?t=${encodeURIComponent(target)}&from=${encodeURIComponent(currentPath)}`;

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
      const w = opt && /^\d+(x\d+)?$/.test(opt.trim()) ? ` style="max-width:${parseInt(opt, 10)}px"` : "";
      const alt = opt && !/^\d/.test(opt) ? opt : file.split("/").pop();
      return `<span class="figure"><img src="${embedURL(file)}" alt="${esc(alt)}" loading="lazy"${w}></span>`;
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
  for (const img of root.querySelectorAll(".figure img")) {
    img.addEventListener("error", () => {
      const s = document.createElement("span");
      s.className = "missing";
      s.textContent = `Abbildung fehlt: ${img.alt}`;
      img.replaceWith(s);
    });
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

window.TW = { render, scrollToHeading };
