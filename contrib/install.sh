#!/usr/bin/env bash
# Install the tuning helper and its polkit action.
#
# Only needed for the "Enable tuning" button in the Fine limits section. Reading
# the gate, switching GPU modes and switching power profiles all work without
# this — asusd.ron is world-readable and asusd's own D-Bus policy already grants
# the rest to `wheel`.
#
#   sudo ./contrib/install.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/asusd-tuning
POLICY=/usr/share/polkit-1/actions/io.github.rawritude.dgpu-control.policy

[ "$(id -u)" -eq 0 ] || { echo "run me as root: sudo $0" >&2; exit 1; }

# The policy pins this exact path; installing the helper anywhere else silently
# downgrades the prompt to the generic pkexec one.
install -Dm755 "$HERE/../bin/asusd-tuning" "$BIN"
install -Dm644 "$HERE/io.github.rawritude.dgpu-control.policy" "$POLICY"

echo "installed:"
echo "  $BIN"
echo "  $POLICY"
echo
echo "current gate:"
"$BIN" status
