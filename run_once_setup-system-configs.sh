#!/bin/sh
# Installs system files that live outside $HOME. Each target is skipped when
# the machine doesn't need it or manages it another way:
# - pam config is only wanted where hyprlock exists, and on NixOS
#   /etc/pam.d/* are module-managed symlinks into /etc/static — overwriting
#   one would fight the generation (and cp fails on the read-only store).
# - /etc/greetd exists only where greetd is installed; on NixOS its
#   config.toml is likewise a module-managed symlink.
if command -v hyprlock >/dev/null 2>&1 \
  && [ -d /etc/pam.d ] && [ ! -L /etc/pam.d/hyprlock ]; then
  sudo cp ~/.config/hypr/pam-hyprlock /etc/pam.d/hyprlock
fi

if [ -d /etc/greetd ] && [ ! -L /etc/greetd/config.toml ]; then
  sudo cp ~/.config/hypr/greetd-config.toml /etc/greetd/config.toml
fi
