#!/bin/bash
#
# Sets up fan and power control for the Open Razer plugin, entirely in the
# user's home directory (no sudo):
#
#   1. gets razer-control-revived (reuses an existing checkout/build, or clones and builds it)
#   2. installs its daemon, razer-cli and laptops.json under ~/.local/share/open-razer
#   3. writes a systemd *user* unit for the daemon (razercontrol.service) and starts it
#   4. installs the plugin's curve service (open-razer-fan.service)
#
# The daemon talks to the Blade's embedded controller over hidraw, so the user
# needs read/write access to /dev/hidraw* for the laptop (Omarchy's udev rule
# gives that to the `input` group). If a distro package of razer-control is
# already installed system-wide, that is used instead of building.
#
# Usage: scripts/setup-fan-backend.sh [--rebuild]

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/.local/share/open-razer"
SRC="${RAZER_CONTROL_SRC:-$HOME/.local/src/razer-control-revived}"
REPO="https://github.com/encomjp/razer-control-revived"
UNIT_DIR="$HOME/.config/systemd/user"
REBUILD=0
[[ ${1:-} == "--rebuild" ]] && REBUILD=1

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. hidraw access -------------------------------------------------------

blade_hidraw() {
  local h id pid
  for h in /sys/class/hidraw/hidraw*; do
    id=$(grep -s '^HID_ID=' "$h/device/uevent" | cut -d= -f2) || continue
    [[ $id == 0003:00001532:* ]] || continue
    pid=${id##*:}
    pid=${pid: -4}
    # Blade control endpoints are the 02xx product ids; mice/keyboards are 00xx/01xx accessories.
    [[ $pid == 02* ]] || continue
    [[ $(cat "$h/device/../bInterfaceNumber" 2>/dev/null || echo 00) == 00 ]] || continue
    echo "/dev/$(basename "$h")"
    return 0
  done
  return 1
}

say "Checking access to the laptop's HID control interface"
node=$(blade_hidraw || true)
if [[ -z $node ]]; then
  warn "no Razer Blade hidraw device found; is this a Razer laptop? Continuing anyway."
elif [[ -r $node && -w $node ]]; then
  say "$node is accessible"
else
  if id -nG | tr ' ' '\n' | grep -qx input; then
    warn "$node is owned by root:input and you're in 'input', but it isn't writable. Check the udev rules in /etc/udev/rules.d/99-razer-omarchy.rules."
  elif getent group input | grep -qE "(:|,)$USER(,|$)"; then
    warn "$node needs the 'input' group. You're a member but this session predates it: log out and back in, then re-run this script."
    NEED_RELOGIN=1
  else
    warn "$node needs the 'input' group. Run:  sudo usermod -aG input $USER  then log out and back in."
    NEED_RELOGIN=1
  fi
fi

# --- 2. binaries ------------------------------------------------------------

if [[ $REBUILD -eq 0 && -x /usr/bin/razer-daemon && -x /usr/bin/razer-cli && -f /usr/lib/systemd/user/razercontrol.service ]]; then
  say "Using the system-wide razer-control install (/usr/bin/razer-daemon)"
  SYSTEM_INSTALL=1
else
  SYSTEM_INSTALL=0
  command -v cargo >/dev/null || die "cargo is required to build razer-control-revived (sudo pacman -S rust)"
  if [[ ! -d $SRC/razer_control_gui ]]; then
    say "Cloning $REPO into $SRC"
    git clone --depth 1 "$REPO" "$SRC"
  fi
  BUILD="$SRC/razer_control_gui/target/release"
  if [[ $REBUILD -eq 1 || ! -x $BUILD/daemon || ! -x $BUILD/razer-cli ]]; then
    say "Building the daemon and razer-cli (no GUI, so no GTK needed)"
    cargo build --release --no-default-features --bin daemon --bin razer-cli \
      --manifest-path "$SRC/razer_control_gui/Cargo.toml"
  else
    say "Reusing the build in $BUILD"
  fi
  mkdir -p "$DEST/bin"
  install -m 755 "$BUILD/daemon" "$DEST/bin/razer-daemon"
  install -m 755 "$BUILD/razer-cli" "$DEST/bin/razer-cli"
  install -m 644 "$SRC/razer_control_gui/data/devices/laptops.json" "$DEST/laptops.json"
  say "Installed to $DEST/bin"
fi

# --- 3. daemon user service -------------------------------------------------

mkdir -p "$HOME/.local/share/razercontrol" "$UNIT_DIR"
if [[ $SYSTEM_INSTALL -eq 0 ]]; then
  cat >"$UNIT_DIR/razercontrol.service" <<UNIT
[Unit]
Description=Razer laptop control daemon (Open Razer user install)
After=default.target

[Service]
Type=simple
Environment=RAZER_DEVICE_FILE=%h/.local/share/open-razer/laptops.json
ExecStartPre=/bin/mkdir -p %h/.local/share/razercontrol
ExecStart=%h/.local/share/open-razer/bin/razer-daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  say "Wrote $UNIT_DIR/razercontrol.service"
fi

systemctl --user daemon-reload
systemctl --user enable --now razercontrol.service || warn "could not start razercontrol.service"

sock="${XDG_RUNTIME_DIR:-/tmp}/razercontrol-socket"
for _ in $(seq 1 20); do
  [[ -S $sock ]] && break
  sleep 0.25
done

cli="$DEST/bin/razer-cli"
[[ -x $cli ]] || cli=/usr/bin/razer-cli
if [[ -S $sock ]] && rpm=$("$cli" read fan-rpm 2>/dev/null | grep -v '^RES:' | tail -1) && [[ $rpm =~ ^-?[0-9]+$ ]]; then
  say "Daemon is up: fan tachometer reads $rpm RPM"
else
  warn "Daemon isn't answering yet. Check:  systemctl --user status razercontrol  (it exits with 'no supported device found' when it can't open the hidraw node)"
fi

# --- 4. curve service -------------------------------------------------------

say "Installing the Open Razer curve service"
python3 "$PLUGIN_DIR/fan_ctl.py" install-service

echo
if [[ ${NEED_RELOGIN:-0} -eq 1 ]]; then
  say "Done, but fan control will only work after you log out and back in (group membership)."
else
  say "Done. Open the Open Razer panel and switch to the Fans tab."
fi
