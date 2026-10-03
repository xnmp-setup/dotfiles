const assert = require('node:assert/strict');
const { extractPalette } = require('./lib/scrivo-obsidian-theme.cjs');

const result = extractPalette(`
/* .theme-dark { --text-normal: fake; } */
body { --text-normal: var(--fg); color: red; }
.theme-light { --fg: #111111; }
.theme-dark { --fg: #eeeeee; --label: "text; {braces}"; }
@media (min-width: 600px) { .theme-dark { --fg: #dddddd !important; padding: 1em; } }
.workspace { display: none; }
@font-face { font-family: custom; src: url(font.woff2); }
`);
assert.match(result, /body\s*\{\s*--text-normal: var\(--fg\)/);
assert.match(result, /\.theme-light\s*\{\s*--fg: #111111/);
assert.match(result, /\.theme-dark\s*\{\s*--fg: #eeeeee/);
assert.match(result, /--label: "text; \{braces\}"/);
assert.match(result, /@media[^]*--fg: #dddddd !important/);
assert.doesNotMatch(result, /fake|color: red|padding:|display:|font-face|workspace/);
assert.throws(() => extractPalette('.theme-dark { --fg: #123456;'), /Unclosed block/);
const documentColors = extractPalette(`
h1, .HyperMD-header-1 { --h1-color: var(--accent); }
strong, .cm-strong { --bold-color: var(--blue); }
em, .cm-em { --italic-color: var(--green); }
.ctp-full-palette { --ctp-accent: var(--ctp-lavender); }
`);
assert.match(documentColors, /\.cm-lp-h1/);
assert.match(documentColors, /\.cm-lp-strong/);
assert.match(documentColors, /\.cm-lp-em/);
assert.match(documentColors, /:where\(\.theme-dark, \.theme-light\)/);
console.log('PASS: Obsidian palette cascade and variable extraction');
