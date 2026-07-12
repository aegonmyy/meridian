// Syncs ../docs/*.md into content/docs/*.mdx for the Fumadocs site.
// Source content is not edited here beyond adding frontmatter and rewriting
// internal links to route slugs. Run after editing anything under docs/.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "fs";
import path from "path";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const srcDir = path.join(repoRoot, "docs");
const outDir = path.join(import.meta.dirname, "../content/docs");

mkdirSync(outDir, { recursive: true });

const order = [
  "index",
  "architecture",
  "withdrawals",
  "resilience",
  "security",
  "design-decisions",
  "development",
  "operations",
  "revert-audit",
  "design-history-audit",
  "docs-findings",
];

const titles = {};

function extractTitle(body) {
  const match = body.match(/^#\s+(.+)$/m);
  return match ? match[1].trim() : "Untitled";
}

function extractDescription(body) {
  const lines = body.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("# ")) {
      for (let j = i + 1; j < lines.length; j++) {
        const line = lines[j].trim();
        if (line.length > 0 && !line.startsWith("#")) {
          return line.replace(/"/g, "'").slice(0, 200);
        }
      }
    }
  }
  return "";
}

function rewriteLinks(body) {
  return body
    .replace(/\]\(\.\.\/README\.md(#[^)]*)?\)/g, (_, anchor) => {
      return `](https://github.com/aegonmyy/meridian/blob/main/README.md${anchor ?? ""})`;
    })
    .replace(/\]\(([a-zA-Z0-9_-]+)\.md\)/g, "]($1)")
    .replace(/\]\(reference\/\)/g, "](/docs/reference)");
}

// MDX does not parse raw HTML comments the way Markdown does. The citation
// comments (<!-- verified: ... -->) are rewritten to JSX comment syntax for
// the website build only; the canonical files under docs/ are untouched.
function rewriteComments(body) {
  return body.replace(/<!--([\s\S]*?)-->/g, (_, inner) => `{/*${inner}*/}`);
}

const files = readdirSync(srcDir).filter((f) => f.endsWith(".md"));

for (const file of files) {
  const slug = file.replace(/\.md$/, "");
  const raw = readFileSync(path.join(srcDir, file), "utf8");
  const title = extractTitle(raw);
  const description = extractDescription(raw);
  titles[slug] = title;

  const body = rewriteComments(rewriteLinks(raw));

  const frontmatter = [
    "---",
    `title: "${title.replace(/"/g, "'")}"`,
    `description: "${description}"`,
    "---",
    "",
  ].join("\n");

  const outName = slug === "index" ? "index.mdx" : `${slug}.mdx`;
  writeFileSync(path.join(outDir, outName), frontmatter + body);
}

const meta = {
  title: "Meridian Docs",
  pages: order.filter((slug) => titles[slug] !== undefined || slug === "index"),
};

writeFileSync(
  path.join(outDir, "meta.json"),
  JSON.stringify(meta, null, 2) + "\n"
);

console.log(`Synced ${files.length} docs into ${outDir}`);
