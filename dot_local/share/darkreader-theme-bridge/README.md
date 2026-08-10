# Dark Reader desktop-theme bridge

`set-theme` downloads a pinned MV3 build from the `xnmp/darkreader` fork and
installs it under:

```text
~/.local/share/darkreader-theme-bridge/extension
```

The fork adds Chrome native messaging to Dark Reader's background worker and
calls Dark Reader's own `Extension.changeSettings()` method when `set-theme`
changes the current palette. The downloaded archive is pinned by release tag
and SHA-256 in `scripts/lib/darkreader-theme.sh`.

The extension retains Dark Reader's official manifest key and extension ID
(`eimadpbcbfnmbkopoojfekhnkhdbieeh`) so existing exports remain compatible.

Before replacing an existing Web Store installation, export its settings from
Dark Reader's **Manage settings** page. Remove the existing Dark Reader from
`chrome://extensions`; loading an unpacked build over it without removal can
leave Chrome's cached Web Store manifest active. Then enable Developer mode,
choose **Load unpacked**, and select the `extension` directory printed by the
script—not its `darkreader-theme-bridge` parent. The selected directory must
directly contain `manifest.json`. Import the saved settings after installation.
The installed name is **Dark Reader (automatic desktop themes)**.

The native host is managed by chezmoi as `host.py`. The unpacked extension is
not tracked in the dotfiles repository and does not receive Chrome Web Store
updates; updates are published as new, checksum-pinned fork releases.
