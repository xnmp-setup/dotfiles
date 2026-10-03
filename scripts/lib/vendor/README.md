PostCSS 8.5.28's parser is bundled here so desktop theme switching needs only
Node.js, without installing npm packages or depending on the Scrivo checkout.
Its bundled dependencies are nanoid, picocolors, and source-map-js; their licenses
are included here as well.
It preserves CSS selectors, variable references, and conditional rules while
discarding Obsidian's application-specific layout rules.

The bundle was built with Bun from PostCSS's `lib/parse.js` CommonJS entry:

```sh
bun build /path/to/node_modules/postcss/lib/parse.js \
  --target=node --format=cjs --minify --outfile postcss-parser.cjs
```

Retain the licenses alongside the bundle when updating it.
