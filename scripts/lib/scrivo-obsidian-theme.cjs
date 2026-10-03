// Keep CSS variables in their original cascade. Parsing the full stylesheet
// handles community themes with nested rules, comments and computed palettes.
const fs = require('node:fs');
const parse = require('./vendor/postcss-parser.cjs');

function extractPalette(css) {
  const root = parse(css, { map: false });
  root.walkComments(comment => comment.remove());
  root.walkDecls(declaration => {
    if (!declaration.prop.startsWith('--')) declaration.remove();
  });
  root.walkRules(rule => {
    const mapped = rule.selectors.map(selector => selector
      .replace(/\.HyperMD-header-([1-6])\b/g, '.cm-lp-h$1')
      .replace(/\.cm-header-([1-6])\b/g, '.cm-lp-h$1')
      .replace(/\.cm-strong\b/g, '.cm-lp-strong')
      .replace(/\.cm-em\b/g, '.cm-lp-em')
      .replace(/(^|[\s>+~,(])h([1-6])(?=$|[\s>+~.#\[:),])/g, '$1.cm-lp-h$2')
      .replace(/(^|[\s>+~,(])strong(?=$|[\s>+~.#\[:),])/g, '$1.cm-lp-strong')
      .replace(/(^|[\s>+~,(])em(?=$|[\s>+~.#\[:),])/g, '$1.cm-lp-em'));
    // Catppuccin's default accent normally comes from the Style Settings
    // plugin's default class. Keep it as a low-priority fallback in Scrivo.
    if (rule.selectors.includes('.ctp-full-palette')) mapped.push(':where(.theme-dark, .theme-light)');
    rule.selectors = [...new Set([...rule.selectors, ...mapped])];
  });
  root.walkAtRules(rule => {
    if (!['media', 'supports', 'layer', 'container'].includes(rule.name)) rule.remove();
  });
  const containers = [];
  root.walk(node => { if (node.nodes) containers.push(node); });
  for (const node of containers.reverse()) {
    if (node.nodes.length === 0) node.remove();
  }
  root.walk(node => { node.raws = {}; });
  return root.toString();
}

// These aliases bridge Obsidian's document colors to Scrivo's renderer. The
// original source declarations remain authoritative, including light variants.
const bridge = `
:where(.theme-dark, .theme-light) {
  --text-title: var(--text-normal);
  --caret-color: var(--text-normal);
  --text-error: var(--color-red, var(--background-modifier-error));
  --blockquote-border-color: var(--background-modifier-border);
  --table-row-alt-background: var(--background-secondary);
  --tok-keyword: var(--code-keyword, var(--color-purple, var(--text-accent)));
  --tok-string: var(--code-string, var(--color-green, var(--text-normal)));
  --tok-number: var(--code-value, var(--color-orange, var(--text-normal)));
  --tok-comment: var(--code-comment, var(--text-muted));
  --tok-function: var(--code-function, var(--color-yellow, var(--text-accent)));
  --tok-type: var(--code-important, var(--color-blue, var(--text-accent)));
  --tok-property: var(--code-property, var(--color-cyan, var(--text-normal)));
  --tok-operator: var(--code-operator, var(--code-punctuation, var(--text-normal)));
  --tok-meta: var(--code-comment, var(--text-muted));
}
html, body {
  --heading: var(--text-title, var(--text-normal));
  --link: var(--link-color, var(--text-accent));
  --code-bg: var(--code-background);
}
.markdown-body strong, .cm-lp-strong { color: var(--bold-color, inherit); }
.markdown-body em, .cm-lp-em { color: var(--italic-color, inherit); }
.markdown-body a[href]:hover, .cm-lp-link:hover { color: var(--link-color-hover, var(--text-accent-hover, var(--link))); }
.markdown-body a:is([href^="https:" i], [href^="http:" i], [href^="mailto:" i], [href^="tel:" i], [href^="//"]),
.cm-lp-link.cm-lp-link-external { color: var(--link-external-color, var(--link)); }
.markdown-body a:is([href^="https:" i], [href^="http:" i], [href^="mailto:" i], [href^="tel:" i], [href^="//"]):hover,
.cm-lp-link.cm-lp-link-external:hover { color: var(--link-external-color-hover, var(--link-external-color, var(--link))); }
.markdown-body pre, .cm-line.cm-lp-codeblock, .cm-lp-code-inline { color: var(--code-normal, var(--text-normal)); }
`;

module.exports = { extractPalette };
if (require.main === module) {
  const source = process.argv[2];
  try {
    process.stdout.write(`\n/* Obsidian palette and document colors. */\n${bridge}\n${extractPalette(fs.readFileSync(source, 'utf8'))}\n`);
  } catch (error) {
    process.stderr.write(`Cannot read Obsidian palette ${source}: ${error.message}\n`);
    process.exitCode = 1;
  }
}
