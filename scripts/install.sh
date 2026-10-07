#!/bin/bash
#
# Installs (or updates) this plugin into ~/.config/omarchy/plugins/<id> and
# enables it in the bar. If the old `dan.razer-chroma` widget is in the bar
# layout, it is swapped for this one in place so it keeps its position.
#
# For a fresh machine you can instead use:  omarchy plugin add <git url> --enable
#
# Usage: scripts/install.sh [--no-enable]

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID=$(jq -r .id "$SRC/manifest.json")
DEST="$HOME/.config/omarchy/plugins/$ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
OLD_ID="dan.razer-chroma"
ENABLE=1
[[ ${1:-} == "--no-enable" ]] && ENABLE=0

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

omarchy-plugin-validate "$SRC"

say "Copying plugin to $DEST"
mkdir -p "$DEST"
if command -v rsync >/dev/null; then
  rsync -a --delete --exclude .git --exclude __pycache__ "$SRC/" "$DEST/"
else
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$SRC/." "$DEST/"
  rm -rf "$DEST/.git"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if [[ $ENABLE -eq 1 ]]; then
  if [[ -f $SHELL_JSON ]] && jq -e --arg old "$OLD_ID" '[.. | objects | select(.id? == $old)] | length > 0' "$SHELL_JSON" >/dev/null; then
    backup="$SHELL_JSON.bak.$(date +%s)"
    cp "$SHELL_JSON" "$backup"
    jq --arg old "$OLD_ID" --arg new "$ID" \
      'walk(if type == "object" and .id? == $old then .id = $new else . end)' "$backup" >"$SHELL_JSON"
    say "Replaced $OLD_ID with $ID in shell.json (backup: $backup)"
    # A widget hosted inside a kristofferr.groups drawer is instantiated from the
    # group's in-memory item list, which only re-reads shell.json on a shell
    # restart; a plain rescan leaves the old id loaded and the new one dormant.
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    if command -v omarchy-restart-shell >/dev/null; then
      say "Restarting the shell so the bar picks up the new widget"
      omarchy-restart-shell >/dev/null 2>&1 || true
    fi
  elif [[ -f $SHELL_JSON ]] && jq -e --arg id "$ID" '[.. | objects | select(.groupId? != null) | .items[]? | select(.id == $id)] | length > 0' "$SHELL_JSON" >/dev/null; then
    # Hosted in a groups drawer: the group reloads hosted widgets unevenly, so
    # one bar can keep running the old copy. A restart loads it cleanly.
    say "$ID is hosted in a group; restarting the shell to reload it"
    command -v omarchy-restart-shell >/dev/null && omarchy-restart-shell >/dev/null 2>&1 || true
  elif omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id and (.enabled == true))' >/dev/null; then
    say "$ID is already enabled"
  else
    section=$(jq -r '.barWidget.defaultSection // "right"' "$SRC/manifest.json")
    for _ in $(seq 1 40); do
      omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null && break
      sleep 0.1
    done
    omarchy-plugin-enable "$ID" --section "$section"
    say "Enabled $ID in the $section bar section"
  fi
fi

# Re-apply saved pointer settings for the mouse right away.
python3 "$DEST/razer_ctl.py" pointer-apply >/dev/null 2>&1 || true

say "Installed. Fan control needs its backend too:  $DEST/scripts/setup-fan-backend.sh"
