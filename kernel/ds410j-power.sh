#!/usr/bin/env bash
# Remote mains control for the DS410j, via the host-side 433 MHz transmitter.
#
# ############################################################################
# # THIS RADIO CONTROLS EVERY OUTLET IN THE OWNER'S HOME.                     #
# #                                                                           #
# # The address below is hardcoded and there is deliberately NO option to     #
# # pass a different one. A mistyped address does not fail - it switches      #
# # something else in someone's house. If you need a different outlet, that   #
# # is a conversation, not an argument to this script.                        #
# ############################################################################
#
# The link is one-way: the transmitter cannot tell us whether the outlet heard
# anything, and it is a hand-built 433 MHz sender that does not work every time.
# So every action is VERIFIED against the DS410j's ethernet carrier - which is
# the one honest indicator of whether the box has power (OPERATIONS.md gotcha 8)
# - and retried up to MAX_TRIES if the carrier does not change.
#
# Why this works at all: as of 2026-09-03 the box powers itself on when AC is
# restored. That is what makes a dumb mains switch a complete power cycle. The
# cause of that behaviour is NOT understood (PORTING.md 3.3), so it may stop
# being true - which is exactly why `cycle` below always ends by trying to
# switch ON, and why leaving the box off is treated as a failure to shout about.
set -uo pipefail

DEV=${DEV:-/dev/ttyS1}
BAUD=${BAUD:-9600}
CARRIER=${CARRIER:-/sys/class/net/eth1/carrier}
LOG=${LOG:-/src/kernel/logs/power.log}
MAX_TRIES=${MAX_TRIES:-3}
ON_TIMEOUT=${ON_TIMEOUT:-45}     # power-on -> PHY link takes a few seconds
OFF_TIMEOUT=${OFF_TIMEOUT:-20}

# The one address this script may ever transmit.
readonly OUTLET="m-FS300 1337 a"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

carrier() { cat "$CARRIER" 2>/dev/null || echo "?"; }

send() { # send on|off
  case "$1" in
    on|off) ;;
    *) echo "send: refusing '$1' - only on/off" >&2; return 1 ;;
  esac
  stty -F "$DEV" "$BAUD" cs8 -cstopb -parenb raw -echo 2>/dev/null || {
    say "ERROR: cannot configure $DEV"; return 1; }
  # Trailing newline is required: the host-side handler reads whole lines, so
  # without it the command sits in the buffer and nothing happens.
  printf '%s %s\n' "$OUTLET" "$1" > "$DEV" || { say "ERROR: write to $DEV failed"; return 1; }
  say "sent: $OUTLET $1"
}

# wait_carrier <0|1> <seconds> -> 0 if it reached the wanted state
wait_carrier() {
  local want=$1 secs=$2 i=0
  while [ "$i" -lt "$secs" ]; do
    [ "$(carrier)" = "$want" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# ensure <on|off> - transmit and verify, retrying a flaky radio
ensure() {
  local what=$1 want timeout
  if [ "$what" = on ]; then want=1; timeout=$ON_TIMEOUT; else want=0; timeout=$OFF_TIMEOUT; fi

  if [ "$(carrier)" = "$want" ]; then
    say "already $what (carrier=$want)"
    return 0
  fi
  local try=1
  while [ "$try" -le "$MAX_TRIES" ]; do
    say "attempt $try/$MAX_TRIES: switching $what"
    send "$what" || return 1
    if wait_carrier "$want" "$timeout"; then
      say "confirmed $what (carrier=$want) after $try attempt(s)"
      return 0
    fi
    say "no carrier change after ${timeout}s - the radio may not have been heard"
    try=$((try + 1))
  done
  say "FAILED to switch $what after $MAX_TRIES attempts (carrier=$(carrier))"
  return 1
}

cycle() {
  local off_secs=${1:-10}
  say "=== cycle: off, ${off_secs}s, on ==="
  if ! ensure off; then
    say "could not switch off; leaving the box alone rather than guessing"
    return 1
  fi
  sleep "$off_secs"
  if ensure on; then
    say "=== cycle complete, box is powered ==="
    return 0
  fi
  # The important failure. Say it loudly and unambiguously.
  say "########################################################"
  say "# THE BOX IS OFF AND WILL NOT COME BACK ON.            #"
  say "# Someone needs to switch the outlet or press the      #"
  say "# front-panel button. Do not assume it will recover.   #"
  say "########################################################"
  return 2
}

status() {
  local c; c=$(carrier)
  echo "carrier      : $c   ($([ "$c" = 1 ] && echo 'powered' || echo 'no power'))"
  printf 'ping         : '; ping -c1 -W2 192.168.50.138 >/dev/null 2>&1 && echo yes || echo no
  echo "outlet       : $OUTLET   (hardcoded; not overridable)"
  echo "serial       : $DEV @ $BAUD"
}

mkdir -p "$(dirname "$LOG")"
case "${1:-status}" in
  status) status ;;
  on)     ensure on ;;
  off)    ensure off ;;
  cycle)  cycle "${2:-10}" ;;
  *) cat <<USAGE
usage: ds410j-power.sh [status|on|off|cycle [off_seconds]]

  status            carrier, ping, and what this script is wired to
  on                switch on,  verified against carrier, up to $MAX_TRIES tries
  off               switch off, verified against carrier
  cycle [secs]      off, wait, on - always ends by trying to switch ON

The outlet address is hardcoded. This radio reaches every outlet in the house.
USAGE
    exit 1 ;;
esac
