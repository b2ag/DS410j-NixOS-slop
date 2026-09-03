#!/usr/bin/env bash
# Is the 88F6281 BootROM's UART recovery path alive on this board?
#
# WHY THIS MATTERS: the project's entire brick-resistance story is currently
# "mtd0 must stay pristine, because it is the only recovery path short of a SOIC
# clip" (CLAUDE.md). If the BootROM answers kwboot, that is false - the SoC has a
# mask-ROM recovery path that no flash write can damage, and the worst case drops
# from "desolder the chip" to "plug in the serial cable".
#
# kwboot(1): "Following power-up or a system reset, system BootROM code polls the
# UART for a brief period of time, sensing a handshake message which initiates an
# image upload." So kwboot must already be running when you power the board on.
#
# THIS TEST WRITES NOTHING. It sends only the handshake and uploads no image, so
# the worst case is that the BootROM sits waiting for an xmodem transfer that
# never comes - cured by a power cycle. It cannot touch flash.
set -uo pipefail

SERIAL_DEV=${SERIAL_DEV:-/dev/ttyUSB0}
MODE=${1:-handshake}
KWBOOT=$(nix-build '<nixpkgs>' -A ubootTools --no-out-link 2>/dev/null)/bin/kwboot

case "$MODE" in
  handshake) ARGS=(-b -t) ;;   # knock, then drop to a terminal
  debug)     ARGS=(-d -t) ;;   # BootROM's built-in console; type ? for help
  *) echo "usage: $0 [handshake|debug]" >&2; exit 1 ;;
esac

# Exactly one reader on the console, or the bytes get split and the handshake
# silently never matches (OPERATIONS.md gotcha 1). Stop the logger for now.
mapfile -t readers < <(pgrep -f "cat ${SERIAL_DEV}" || true)
if [ ${#readers[@]} -gt 0 ]; then
  echo "==> stopping serial logger (pids: ${readers[*]})"
  kill "${readers[@]}" 2>/dev/null || true
  sleep 1
fi

# Deliberately does NOT restart the serial logger on exit. It used to, and that
# was wrong: every failed attempt resurrected the reader you had just killed, so
# the port never stayed free long enough to retry. Restart it yourself when done:
#   setsid /src/kernel/serlog.sh & disown

cat <<EOF
==> running: kwboot ${ARGS[*]} $SERIAL_DEV

    POWER THE BOARD ON NOW (it must be OFF when this starts).

    What you are looking for:
      "Sending boot message. Please reboot the target..."   <- knocking
      "Handshake with bootrom established"                  <- IT WORKS
    If instead you see the normal "U-Boot 1.1.4" banner scroll past, the
    BootROM did not answer and the board booted from flash as usual.

    Ctrl-\\ to quit kwboot's terminal.
EOF
echo
"$KWBOOT" "${ARGS[@]}" "$SERIAL_DEV"
