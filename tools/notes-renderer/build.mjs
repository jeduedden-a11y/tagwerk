// Bundles the renderer into App/Resources/Notes (flat names; the app serves them by file name).
import { build } from "esbuild";
import { copyFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const out = "../../App/Resources/Notes";
rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, "fonts"), { recursive: true });
await build({ entryPoints: ["src/main.js"], bundle: true, minify: true, format: "iife", target: ["safari17"], outfile: join(out, "notes.js"), legalComments: "eof" });
copyFileSync("src/notes.css", join(out, "notes.css"));
copyFileSync("src/notes.html", join(out, "notes.html"));
copyFileSync("node_modules/katex/dist/katex.min.css", join(out, "katex.min.css"));
for (const f of readdirSync("node_modules/katex/dist/fonts")) if (f.endsWith(".woff2")) copyFileSync(join("node_modules/katex/dist/fonts", f), join(out, "fonts", f));
console.log("notes renderer built");
