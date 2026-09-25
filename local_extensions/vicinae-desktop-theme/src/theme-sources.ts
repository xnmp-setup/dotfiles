import { join } from "node:path";

// Vicinae looks for theme TOMLs in the user data dir first, then in the
// system data dirs (where its built-in themes such as Nord live).
export const themeDirectories = (
  env: Readonly<Record<string, string | undefined>>,
  home: string,
): readonly string[] => {
  const dataHome = env.XDG_DATA_HOME ?? join(home, ".local/share");
  const dataDirectories = (env.XDG_DATA_DIRS ?? "/usr/local/share:/usr/share")
    .split(":")
    .filter(Boolean);
  return Array.from(
    new Set([dataHome, ...dataDirectories].map((path) => join(path, "vicinae/themes"))),
  );
};

export const findThemeFile = (
  directories: readonly string[],
  slug: string,
  exists: (path: string) => boolean,
): string | undefined =>
  directories.map((directory) => join(directory, `${slug}.toml`)).find(exists);
