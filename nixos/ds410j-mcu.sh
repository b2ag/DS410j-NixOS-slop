#!/bin/sh
# Send one command character to the DS410j board microcontroller.
#
# The MCU sits on UART1 (serial@12100) at 9600 8N1, exposed as /dev/ttyS1, and
# takes single ASCII characters. It owns the front-panel power and status lamps,
# the buzzer, and the power rail. See OPERATIONS.md, "The board microcontroller
# on /dev/ttyS1", for the full map and how it was derived.
#
#   2 short beep    4 power LED steady     7 status off    9 status green blink
#   3 long beep     5 power LED blinking   8 status green  : ; status orange
#                   6 power LED off
#
# SAFETY: this helper accepts only the codes above - lamps, buzzer, nothing else.
# It will not send '1', which powers the box off, nor 't', which is unidentified
# and appears in DSM's shutdown path. The reason is unchanged by warm reboot now
# working: a soft-off DS410j stays off and needs a human at the front panel
# (PORTING.md 3.3), so an accidental '1' from a system service strands the box.
#
# It will not send 'C' either, even though that is the working warm-reboot
# command. Restarting is not a lamp operation: it belongs to the synology-mcu
# driver's SYS_OFF_MODE_RESTART handler, which is what makes `systemctl reboot`
# work, so that a reboot goes through shutdown rather than cutting the box off
# mid-write.
set -u

# Preferred transport: the synology-mcu driver's debugfs interface. Once that
# driver binds UART1 as a serdev client it owns the port exclusively and
# /dev/ttyS1 no longer exists, so the character device is the fallback, not the
# default - it is still the right answer on a kernel built without the module.
MCU_DBG=${MCU_DBG:-/sys/kernel/debug/synology-mcu/send}
MCU_DEV=${MCU_DEV:-/dev/ttyS1}

case "${1:-}" in
  2|3|4|5|6|7|8|9|:|';') ;;
  *)
    echo "ds410j-mcu: refusing '${1:-}' - not a known-safe MCU code" >&2
    exit 1
    ;;
esac

# The driver's interface needs no termios setup - it fixed the port at 9600 8N1
# when it bound. A single write of the character is the whole protocol.
if [ -w "$MCU_DBG" ]; then
  printf '%s' "$1" > "$MCU_DBG"
  exit $?
fi

# Absent or unwritable is not an error: it just means there is no MCU to talk to
# (a different board, or the unit tests). Say nothing and succeed.
[ -w "$MCU_DEV" ] || exit 0

stty -F "$MCU_DEV" 9600 cs8 -cstopb -parenb raw -echo 2>/dev/null || exit 1
printf '%s' "$1" > "$MCU_DEV"
