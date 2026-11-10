#!/usr/bin/env bash
# install.sh — put Pulse where Omarchy looks for a plugin.
#
# Deliberately does one thing: copy this checkout into the plugin directory and
# tell the running shell to rescan. No sudo, no system files touched, nothing
# outside the user's own ~/.config.
#
#   ./install.sh            install or update
#   ./install.sh --link     symlink instead of copy, for hacking on a checkout
#   ./install.sh --remove   uninstall, restoring the desktop first

set -euo pipefail

PLUGIN_ID="io.github.shapesv.pulse"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-pulse"

say() { printf '\033[1mpulse\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mpulse\033[0m %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is required"

remove() {
  if [[ -d "$DEST" ]]; then
    # Let the daemon put the desktop back before its files disappear.
    if [[ -x "$DEST/bin/pulse-ctl" ]]; then
      python3 "$DEST/bin/pulse-ctl" stop >/dev/null 2>&1 || true
    fi
    systemctl --user disable --now pulse.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/pulse.service"
    systemctl --user daemon-reload 2>/dev/null || true
    rm -rf "$DEST"
    say "removed $DEST"
  else
    say "nothing to remove at $DEST"
  fi
  rm -rf "$STATE"
  command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  say "the desktop is back to its baseline; add the widget back with: omarchy plugin enable $PLUGIN_ID"
}

install_plugin() {
  local link="${1:-}"
  mkdir -p "$(dirname "$DEST")"

  if [[ -d "$DEST" && ! -L "$DEST" && "$SRC" != "$DEST" ]]; then
    say "existing install found, replacing it (config in ~/.config/omarchy-pulse is kept)"
    rm -rf "$DEST"
  fi
  [[ -L "$DEST" ]] && rm -f "$DEST"

  if [[ "$link" == "--link" ]]; then
    ln -sfn "$SRC" "$DEST"
    say "linked $DEST -> $SRC"
  elif [[ "$SRC" != "$DEST" ]]; then
    mkdir -p "$DEST"
    # Everything except the development leftovers.
    tar -C "$SRC" -cf - \
      --exclude=.git --exclude=node_modules --exclude=__pycache__ \
      . | tar -C "$DEST" -xf -
    say "installed to $DEST"
  fi

  chmod +x "$DEST/bin/pulse-ctl"

  # The unit lives in the plugin, not in ~/.config/systemd, so an update ships
  # its own service definition and an uninstall takes it away again.
  mkdir -p "$HOME/.config/systemd/user"
  install -m 644 "$DEST/systemd/pulse.service" "$HOME/.config/systemd/user/pulse.service"

  command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

  systemctl --user daemon-reload
  systemctl --user enable --now pulse.service
  sleep 1
  systemctl --user is-active --quiet pulse.service \
    && say "pulse.service is running" \
    || say "pulse.service did not start; check: journalctl --user -u pulse -n 30"

  cat <<EOF

next:
  omarchy plugin enable $PLUGIN_ID     put the widget on the bar
  python3 $DEST/bin/pulse-ctl status   see what it currently thinks
  journalctl --user -u pulse -f        watch it change profiles
EOF
}

case "${1:-}" in
  --remove) remove ;;
  --link)   install_plugin --link ;;
  "")       install_plugin ;;
  *)        die "unknown option: $1" ;;
esac