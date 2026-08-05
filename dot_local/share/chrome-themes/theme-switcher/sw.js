// Desktop Theme Switcher — service worker.
//
// Holds a native-messaging port to `com.chong.theme_switcher` (the host script
// at ~/.local/bin/chrome-theme-switcher-host, installed by set-theme.sh). The
// host watches ~/.local/state/chrome-theme-switcher/current and pushes
// {title: "Golden Hour Light"} whenever set-theme writes it.
//
// Applying a theme is just enabling the installed theme extension whose name
// matches: Chrome allows exactly one enabled theme and disables the previous
// one itself. Themes must already be installed (loaded unpacked once per
// machine) — an unknown title is a no-op, not an error.

const HOST = 'com.chong.theme_switcher';

// Reconnect backoff. The host also exits whenever the port drops, so a dead
// worker leaves nothing behind; the next wake-up starts a fresh pair.
const BACKOFF_MIN_MS = 1000;
const BACKOFF_MAX_MS = 60000;
let backoff = BACKOFF_MIN_MS;
let port = null;

async function applyTheme(title) {
  const all = await chrome.management.getAll();
  const theme = all.find((e) => e.type === 'theme' && e.name === title);
  if (!theme) {
    console.warn(`[theme-switcher] no installed theme named "${title}"`);
    return;
  }
  if (theme.enabled) return;
  await chrome.management.setEnabled(theme.id, true);
  console.log(`[theme-switcher] enabled "${title}"`);
}

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    // No host manifest installed yet — retry, the user may run set-theme next.
    port = null;
    schedule();
    return;
  }

  port.onMessage.addListener((msg) => {
    // Any message resets the worker's idle timer, which is why the host sends
    // periodic pings; only {title} carries work.
    backoff = BACKOFF_MIN_MS;
    if (msg && typeof msg.title === 'string') applyTheme(msg.title);
  });

  port.onDisconnect.addListener(() => {
    port = null;
    schedule();
  });
}

function schedule() {
  const delay = backoff;
  backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
  setTimeout(connect, delay);
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// Also connect when the worker is revived by any other event (or by the
// browser restarting it after an idle teardown).
connect();
