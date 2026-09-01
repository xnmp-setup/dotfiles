import assert from "node:assert/strict";
import test from "node:test";
import {
  orderDesktopThemes,
  parseDesktopTheme,
  slugifyThemeTitle,
  themeApplyArguments,
} from "./theme-domain.ts";

const fixture = `
[meta]
name = "Test Theme"
description = "A complete test palette"
variant = "dark"

[colors.core]
foreground = "#eeeeee"
accent = "#123456"

[colors.accents]
blue = "#0000ff"
green = "#00ff00"
magenta = "#ff00ff"
orange = "#ff8800"
red = "#ff0000"
yellow = "#ffff00"
cyan = "#00ffff"
`;

test("parses the ordered eight-color desktop palette", () => {
  const theme = parseDesktopTheme("test-theme", fixture);

  assert.deepEqual(theme, {
    slug: "test-theme",
    title: "Test Theme",
    description: "A complete test palette",
    variant: "dark",
    accent: "#123456",
    palette: [
      "#ff0000",
      "#0000ff",
      "#00ffff",
      "#00ff00",
      "#ffff00",
      "#ff00ff",
      "#ff8800",
      "#eeeeee",
    ],
  });
});

test("rejects themes without a complete palette", () => {
  assert.throws(
    () => parseDesktopTheme("broken", fixture.replace('red = "#ff0000"', "")),
    /missing required Vicinae palette metadata/,
  );
});

test("separates the current theme without duplicating it", () => {
  const current = parseDesktopTheme("test-theme", fixture);
  const available = parseDesktopTheme(
    "other-theme",
    fixture.replace('name = "Test Theme"', 'name = "Other Theme"'),
  );

  assert.deepEqual(orderDesktopThemes([current, available], "test-theme"), {
    current,
    available: [available],
  });
});

test("builds a worker argument vector without shell interpolation", () => {
  assert.deepEqual(themeApplyArguments("/tmp/apply-theme", "theme;unsafe", "Unsafe Theme"), [
    "bash",
    "/tmp/apply-theme",
    "theme;unsafe",
    "Unsafe Theme",
  ]);
  assert.equal(slugifyThemeTitle("  Flexoki   Light "), "flexoki-light");
});
