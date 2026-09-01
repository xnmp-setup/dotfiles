export type ThemeVariant = "dark" | "light";

export type DesktopTheme = Readonly<{
  slug: string;
  title: string;
  description: string;
  variant: ThemeVariant;
  accent: string;
  palette: readonly string[];
}>;

const quotedValue = (source: string, key: string): string | undefined => {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return source.match(new RegExp(`^${escapedKey}\\s*=\\s*"([^"]*)"`, "m"))?.[1];
};

const section = (source: string, name: string): string => {
  const lines = source.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === `[${name}]`);
  if (start < 0) return "";

  const followingHeader = lines
    .slice(start + 1)
    .findIndex((line) => /^\[[^\]]+\]$/.test(line.trim()));
  const end = followingHeader < 0 ? lines.length : start + 1 + followingHeader;
  return lines.slice(start + 1, end).join("\n");
};

export const slugifyThemeTitle = (title: string): string =>
  title.toLowerCase().trim().replace(/\s+/g, "-");

export const parseDesktopTheme = (
  slug: string,
  source: string,
): DesktopTheme => {
  const meta = section(source, "meta");
  const core = section(source, "colors.core");
  const accents = section(source, "colors.accents");
  const title = quotedValue(meta, "name");
  const description = quotedValue(meta, "description");
  const variant = quotedValue(meta, "variant");
  const accent = quotedValue(core, "accent");
  const foreground = quotedValue(core, "foreground");
  const palette = ["red", "blue", "cyan", "green", "yellow", "magenta", "orange"]
    .map((name) => quotedValue(accents, name))
    .concat(foreground)
    .filter((color): color is string => Boolean(color));

  if (!title || !description || !accent || palette.length !== 8) {
    throw new Error(`Theme ${slug} is missing required Vicinae palette metadata`);
  }
  if (variant !== "dark" && variant !== "light") {
    throw new Error(`Theme ${slug} has invalid variant ${variant ?? "<missing>"}`);
  }

  return Object.freeze({
    slug,
    title,
    description,
    variant,
    accent,
    palette: Object.freeze(palette),
  });
};

export const orderDesktopThemes = (
  themes: readonly DesktopTheme[],
  currentSlug?: string,
): Readonly<{ current?: DesktopTheme; available: readonly DesktopTheme[] }> => {
  const current = themes.find(({ slug }) => slug === currentSlug);
  const available = themes.filter(({ slug }) => slug !== currentSlug);
  return Object.freeze({ current, available: Object.freeze(available) });
};

export const themeApplyArguments = (
  worker: string,
  slug: string,
  title: string,
): readonly string[] => Object.freeze(["bash", worker, slug, title]);
