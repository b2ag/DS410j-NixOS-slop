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
# SAFETY: this helper accepts only the codes above. It will not send '1', which
# powers the box off, nor 't', which is unidentified and appears in DSM's
# shutdown path. Nothing running as a system service should be able to cut power
# by getting a character wrong, and a warm reboot does not work on this board
# (PORTING.md 3.3) - an accidental poweroff needs a human at the front panel.
set -u

MCU_DEV=${MCU_DEV:-/dev/ttyS1}

case "${1:-}" in
  2|3|4|5|6|7|8|9|:|';') ;;
  *)
    echo "ds410j-mcu: refusing '${1:-}' - not a known-safe MCU code" >&2
    exit 1
    ;;
esac

# Absent or unwritable is not an error: it just means there is no MCU to talk to
# (a different board, or the unit tests). Say nothing and succeed.
[ -w "$MCU_DEV" ] || exit 0

stty -F "$MCU_DEV" 9600 cs8 -cstopb -parenb raw -echo 2>/dev/null || exit 1
printf '%s' "$1" > "$MCU_DEV"
