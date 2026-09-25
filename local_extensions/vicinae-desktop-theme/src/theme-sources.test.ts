import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import test from "node:test";
import { parseDesktopTheme, slugifyThemeTitle } from "./theme-domain.ts";
import { findThemeFile, themeDirectories } from "./theme-sources.ts";

// `npm test` runs from the package directory, local_extensions/<name>.
const repoRoot = join(process.cwd(), "../..");
const repoThemes = join(repoRoot, "dot_local/share/vicinae/themes");

test("user data dir takes precedence over system data dirs", () => {
  const directories = themeDirectories(
    { XDG_DATA_HOME: "/data", XDG_DATA_DIRS: "/sys-a:/sys-b" },
    "/home/u",
  );
  assert.deepEqual(directories, [
    "/data/vicinae/themes",
    "/sys-a/vicinae/themes",
    "/sys-b/vicinae/themes",
  ]);

  const present = new Set(["/data/vicinae/themes/nord.toml", "/sys-b/vicinae/themes/nord.toml"]);
  assert.equal(
    findThemeFile(directories, "nord", (path) => present.has(path)),
    "/data/vicinae/themes/nord.toml",
  );
});

test("falls back to XDG defaults and ignores empty data dir entries", () => {
  assert.deepEqual(themeDirectories({}, "/home/u"), [
    "/home/u/.local/share/vicinae/themes",
    "/usr/local/share/vicinae/themes",
    "/usr/share/vicinae/themes",
  ]);
  assert.deepEqual(themeDirectories({ XDG_DATA_DIRS: "::/x:" }, "/h"), [
    "/h/.local/share/vicinae/themes",
    "/x/vicinae/themes",
  ]);
});

test("a missing theme resolves to undefined", () => {
  assert.equal(findThemeFile(["/a", "/b"], "absent", () => false), undefined);
});

// The menu finds a theme's palette by slugifying its title, so each repo TOML
// must parse and be named after its own [meta].name.
test("every repo theme parses and is named after its title", () => {
  const files = readdirSync(repoThemes).filter((name) => name.endsWith(".toml"));
  assert.ok(files.length > 0);
  for (const file of files) {
    const slug = basename(file, ".toml");
    const theme = parseDesktopTheme(slug, readFileSync(join(repoThemes, file), "utf8"));
    assert.equal(slugifyThemeTitle(theme.title), slug, file);
  }
});

// Integration: the extension silently drops any listed theme it cannot resolve
// or parse. This includes Vicinae's built-in themes, which change with upgrades.
test("every theme set-theme lists appears in the menu", () => {
  const listing = spawnSync("bash", [join(repoRoot, "scripts/set-theme.sh"), "--list-desktop-themes"], {
    encoding: "utf8",
  });
  assert.equal(listing.status, 0, listing.stderr);
  const directories = themeDirectories(process.env, homedir());
  for (const title of listing.stdout.split("\n").map((line) => line.trim()).filter(Boolean)) {
    const slug = slugifyThemeTitle(title);
    const path = findThemeFile(directories, slug, existsSync);
    assert.ok(path, `no Vicinae theme file for ${title}`);
    assert.doesNotThrow(() => parseDesktopTheme(slug, readFileSync(path, "utf8")), title);
  }
});
