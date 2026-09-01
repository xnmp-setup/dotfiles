import {
  Action,
  ActionPanel,
  Icon,
  List,
  PopToRootType,
  Toast,
  showHUD,
  showToast,
} from "@vicinae/api";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { useEffect, useState } from "react";
import {
  type DesktopTheme,
  orderDesktopThemes,
  parseDesktopTheme,
  slugifyThemeTitle,
  themeApplyArguments,
} from "./theme-domain";

type ThemeState = Readonly<{
  themes: readonly DesktopTheme[];
  currentSlug?: string;
  error?: string;
  loading: boolean;
}>;

const home = homedir();
const themeCli = join(home, ".local/share/chezmoi/scripts/set-theme.sh");
const themeWorker = join(
  home,
  ".local/share/chezmoi/scripts/apply-desktop-theme-worker",
);
const dataHome = process.env.XDG_DATA_HOME ?? join(home, ".local/share");
const dataDirectories = (
  process.env.XDG_DATA_DIRS ?? "/usr/local/share:/usr/share"
)
  .split(":")
  .filter(Boolean);
const themeDirectories = Array.from(
  new Set([dataHome, ...dataDirectories].map((path) => join(path, "vicinae/themes"))),
);
const stateDirectory = process.env.XDG_STATE_HOME ?? join(home, ".local/state");
const currentThemeFile = join(stateDirectory, "desktop-theme/current.json");

const readThemeSource = (slug: string): string => {
  const path = themeDirectories
    .map((directory) => join(directory, `${slug}.toml`))
    .find(existsSync);
  if (!path) {
    throw new Error(`No Vicinae palette is installed for ${slug}`);
  }
  return readFileSync(path, "utf8");
};

const loadThemeState = (): ThemeState => {
  const titles = spawnSyncOutput("bash", [themeCli, "--list-desktop-themes"])
    .split("\n")
    .map((title) => title.trim())
    .filter(Boolean);
  const themes = titles.flatMap((title) => {
    const slug = slugifyThemeTitle(title);
    try {
      return [parseDesktopTheme(slug, readThemeSource(slug))];
    } catch {
      return [];
    }
  });
  if (themes.length === 0) {
    throw new Error("No complete desktop themes are installed");
  }

  let currentSlug: string | undefined;
  try {
    const saved: unknown = JSON.parse(readFileSync(currentThemeFile, "utf8"));
    currentSlug =
      typeof saved === "object" &&
      saved !== null &&
      "slug" in saved &&
      typeof saved.slug === "string"
        ? saved.slug
        : undefined;
  } catch {
    currentSlug = undefined;
  }

  return { themes, currentSlug, loading: false };
};

const spawnSyncOutput = (command: string, args: readonly string[]): string => {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || `Failed to run ${command}`);
  }
  return result.stdout;
};

const startDesktopThemeApply = async (theme: DesktopTheme): Promise<void> => {
  const child = spawn(
    "/usr/bin/env",
    [...themeApplyArguments(themeWorker, theme.slug, theme.title)],
    {
      detached: true,
      env: process.env,
      stdio: "ignore",
    },
  );

  await new Promise<void>((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  child.unref();

  await showHUD(`Applying ${theme.title}`, {
    clearRootSearch: true,
    popToRootType: PopToRootType.Immediate,
  });
};

const paletteAccessories = (theme: DesktopTheme): List.Item.Accessory[] =>
  theme.palette.map((color) => ({
    icon: { source: Icon.CircleFilled, tintColor: color },
    tooltip: color,
  }));

const ThemeItem = ({ theme }: { theme: DesktopTheme }) => (
  <List.Item
    id={theme.slug}
    title={theme.title}
    subtitle={theme.description}
    keywords={[theme.slug, theme.variant, "desktop", "wallpaper"]}
    icon={{
      source: theme.variant === "light" ? Icon.Sun : Icon.Moon,
      tintColor: theme.accent,
    }}
    accessories={paletteAccessories(theme)}
    actions={
      <ActionPanel>
        <Action
          title={`Apply ${theme.title}`}
          icon={Icon.Desktop}
          onAction={async () => {
            try {
              await startDesktopThemeApply(theme);
            } catch (error) {
              await showToast({
                style: Toast.Style.Failure,
                title: "Desktop theme was not started",
                message: error instanceof Error ? error.message : String(error),
              });
            }
          }}
        />
      </ActionPanel>
    }
  />
);

export default function SetDesktopTheme() {
  const [state, setState] = useState<ThemeState>({ themes: [], loading: true });

  useEffect(() => {
    try {
      setState(loadThemeState());
    } catch (error) {
      setState({
        themes: [],
        loading: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }, []);

  const { current, available } = orderDesktopThemes(
    state.themes,
    state.currentSlug,
  );

  return (
    <List
      isLoading={state.loading}
      navigationTitle="Set Desktop Theme"
      searchBarPlaceholder="Search desktop themes…"
    >
      {state.error ? (
        <List.EmptyView
          icon={Icon.Exclamationmark}
          title="Desktop themes could not be loaded"
          description={state.error}
        />
      ) : null}
      {current ? (
        <List.Section title="Current Desktop Theme">
          <ThemeItem theme={current} />
        </List.Section>
      ) : null}
      <List.Section title={`Desktop Themes (${state.themes.length})`}>
        {available.map((theme) => (
          <ThemeItem key={theme.slug} theme={theme} />
        ))}
      </List.Section>
    </List>
  );
}
