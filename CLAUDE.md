Use chezmoi apply, after changes, but only to the files changed. 
DO NOT chezmoi apply without viewing the diff first. DO NOT use --force

## Portability

These dotfiles are applied on NixOS, Arch, macOS, and WSL(Ubuntu)/Windows. Any config
you add must work on all four — a change that assumes one of them is broken on
the other three.

- Never branch on a specific machine (hostname, a particular laptop's name).
  Branch on the *property* that actually differs: the OS, the presence of a
  binary, whether a feature is installed. Machine names go stale and don't
  describe why the branch exists.
- Prefer runtime capability detection over apply-time templating. A script that
  checks for what it needs and degrades gracefully stays correct when a machine
  gains or loses that thing; a template baked at apply time does not.
- Where a config depends on something outside this repo (a NixOS module, a
  package, a system file), say so in a comment, and make the config's behaviour
  when that thing is absent both deliberate and safe.

When making a change, double check that it won't break anything on the other platforms. 
If it's a high risk change, run an adversarial reviewer to verify this. 

- If adding laptop-specific functionality, gate it behind a check that the machine is a laptop (eg checking its battery)
