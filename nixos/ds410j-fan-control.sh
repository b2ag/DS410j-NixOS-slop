#!/bin/sh
# Fan and bay-LED control for the Synology DS410j.
#
# Two temperature inputs, because the box has two kinds of hot thing:
#
#   BOARD   an LM75-compatible sensor at I2C 0x48 (PORTING.md 3.3). This is the
#           ambient the fan actually moves, and on the bench it runs hotter than
#           either drive - 46 C at idle against drives at 43 and 40.
#   DRIVES  each SATA drive's own sensor via CONFIG_SENSORS_DRIVETEMP.
#
# They need SEPARATE thresholds. The board idling at 46 C sits only a few degrees
# under the drive threshold, so sharing one number would leave the fan escalated
# permanently. Each input is measured in degrees above its own threshold, and the
# more urgent one wins.
#
# Interfaces used:
#   /sys/class/hwmon/hwmon*/name = lm75*             board temperature
#   /sys/block/sd*/device/hwmon/hwmon*/temp1_input   drive temperature, milli-C
#   /sys/class/hwmon/hwmon*/name = gpio_fan          fan1_target, in rpm
#   /sys/class/leds/synology:{green,amber}:hddN      bay LEDs
#
# SAFETY: this script never selects fan speed 0. The gpio-fan speed map has one
# (ctrl 0 = off) and writing 0 to fan1_target would select it; the lowest speed
# used here is 2200 rpm. It also never stops the fan on exit, so if the daemon
# dies the fan holds its last speed.
#
# NOTE ON SPINDOWN: drivetemp has no standby check, so each poll wakes a parked
# drive. Harmless today because spindown is not enabled; if it ever is, gate the
# drive read on `hdparm -C`. The board sensor has no such problem, which is
# another argument for it being the primary input.
set -u

POLL=${POLL:-30}

# Prefix for every sysfs path, so the logic can be exercised against a fake tree.
# Empty in production. See test-fan-control.sh.
SYSROOT=${SYSROOT:-}

# Available speeds, ascending. From gpio-fan,speed-map in kirkwood-ds410j.dts,
# with the 0 (= fan OFF) entry deliberately omitted - see SAFETY above.
SPEEDS="2200 2500 3000 3300 3700 3800 4200"
NSPEEDS=7

# Policy, all overridable from the NixOS module. Hold BASELINE_RPM until an input
# passes its threshold, then add one speed step per STEP_C degrees beyond it;
# return to baseline only once every input is HYST_C below its own threshold.
#
# The baseline is a floor, not a target. It defaults to the quietest speed rather
# than the 3300 rpm U-Boot pins, which is an arbitrary bring-up pick and not a
# hardware default.
BASELINE_RPM=${BASELINE_RPM:-2200}
STEP_C=${STEP_C:-3}
HYST_C=${HYST_C:-3}

# Board: idles around 46 C, so 55 leaves real headroom before the fan reacts.
# The LM75's own limit registers read 80/75 C, which is the chip's ceiling rather
# than the board's, but it anchors the warn level.
BOARD_ESCALATE_C=${BOARD_ESCALATE_C:-55}
BOARD_WARN_C=${BOARD_WARN_C:-70}

# Drives: 3.5" spinners are generally rated to 55-60 C.
DRIVE_ESCALATE_C=${DRIVE_ESCALATE_C:-50}
DRIVE_WARN_C=${DRIVE_WARN_C:-55}

idx=$NSPEEDS    # start at the top speed so a first pass that cannot read
escalated=0     # anything fails safe. escalated stays 0 so hysteresis cannot
                # hold that artificial value against the first real reading.
last_written=""
last_state=""
last_status=""

log() { echo "ds410j-fan: $*"; }

# nth <index> <space-separated list>   (1-based)
nth() {
  _n=$1
  shift
  # shellcheck disable=SC2086
  set -- $1
  eval "echo \${$_n}"
}

# Optional: path to ds410j-mcu.sh. When set, the front-panel status lamp follows
# the same fault condition as the amber bay LEDs. Left unset (a no-op) outside
# NixOS, which is what the tests do.
MCU=${MCU:-}
mcu_set() {
  [ -n "$MCU" ] || return 0
  [ "$1" = "$last_status" ] && return 0
  $MCU "$1" 2>/dev/null || true
  last_status=$1
}

find_fan() {
  for h in "$SYSROOT"/sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    read -r _name < "$h/name" || continue
    if [ "$_name" = "gpio_fan" ] && [ -w "$h/fan1_target" ]; then
      echo "$h/fan1_target"
      return 0
    fi
  done
  return 1
}

# The board sensor. Matched on an lm75* prefix so that re-typing the chip - lm75
# versus lm75b, which changes the reported resolution - does not break this.
find_board() {
  for h in "$SYSROOT"/sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    read -r _name < "$h/name" || continue
    case "$_name" in
      lm75*) [ -r "$h/temp1_input" ] && { echo "$h/temp1_input"; return 0; } ;;
    esac
  done
  return 1
}

read_temp_c() { # read_temp_c <path> -> degrees C, or nothing
  [ -r "$1" ] || return 1
  read -r _milli < "$1" 2>/dev/null || return 1
  case "$_milli" in ''|*[!0-9-]*) return 1 ;; esac
  echo $((_milli / 1000))
}

# One "bay temp" line per SATA drive. A drive whose sensor cannot be read still
# produces a line, with a temp of "-", so presence and temperature stay
# distinguishable: a present-but-unreadable drive must fail safe, an empty bay
# must not.
scan_drives() {
  for blk in "$SYSROOT"/sys/block/sd*; do
    [ -e "$blk/device" ] || continue
    # e.g. .../0000:01:00.0/ata4/host4/target4:0:0/4:0:0:0 -> bay 4. The USB boot
    # stick resolves through .../usb1/... with no ataN component, which is how it
    # gets skipped.
    phys=$(readlink -f "$blk/device" 2>/dev/null) || continue
    case "$phys" in
      */ata[0-9]*) ;;
      *) continue ;;
    esac
    bay=${phys##*/ata}
    bay=${bay%%/*}
    case "$bay" in ''|*[!0-9]*) continue ;; esac

    temp='-'
    for hw in "$blk"/device/hwmon/hwmon*; do
      t=$(read_temp_c "$hw/temp1_input") && { temp=$t; break; }
    done
    echo "$bay $temp"
  done
}

set_led() { # set_led <name> <0|1>
  _l="$SYSROOT/sys/class/leds/$1/brightness"
  [ -w "$_l" ] && echo "$2" > "$_l" 2>/dev/null
  return 0
}

update_leds() { # update_leds <drives-listing>
  for bay in 1 2 3 4; do
    present=0
    hot=0
    while read -r b t; do
      [ "$b" = "$bay" ] || continue
      present=1
      if [ "$t" != "-" ] && [ "$t" -ge "$DRIVE_WARN_C" ]; then hot=1; fi
    done <<EOF
$1
EOF
    # The two pins for a bay are NOT independent lamps. They drive one bi-colour
    # LED, confirmed on hardware:
    #
    #   even pin high, odd low  -> amber, with or without a drive
    #   odd pin high, even low  -> green, but ONLY with a drive fitted
    #   both high, or both low  -> dark
    #
    # So they are mutually exclusive, and the order matters: clear the other pin
    # first, or the lamp blinks off in between. Amber wins, because "this drive
    # is too hot" must not be rendered as "no lamp at all".
    if [ "$hot" = 1 ]; then
      set_led "synology:green:hdd$bay" 0
      set_led "synology:amber:hdd$bay" 1
    else
      set_led "synology:amber:hdd$bay" 0
      set_led "synology:green:hdd$bay" "$present"
    fi
  done
}

# steps_for <temp> <threshold>  -> speed steps above baseline, 0 if under
steps_for() {
  [ "$1" -ge "$2" ] || { echo 0; return; }
  echo $(( 1 + ($1 - $2) / STEP_C ))
}

fan=$(find_fan) || {
  log "no gpio_fan hwmon device with a writable fan1_target."
  log "CONFIG_SENSORS_GPIO_FAN missing, or the DT node failed to probe - check dmesg."
  log "leaving the fan at whatever the bootloader set; not touching it."
  exit 1
}
board=$(find_board) || board=""
if [ -n "$board" ]; then
  log "using $fan, board sensor $board, polling every ${POLL}s"
else
  log "WARNING: no lm75* board sensor found - is the DT node present? (PORTING.md 3.3)"
  log "falling back to drive temperatures only. using $fan, polling every ${POLL}s"
fi

while : ; do
  drives=$(scan_drives)
  board_t=$(read_temp_c "$board" 2>/dev/null) || board_t=""

  n_present=0
  n_readable=0
  maxd=-1
  # A here-doc, not a pipe: a pipeline runs the loop in a subshell and the
  # counters would not survive it.
  while read -r bay t; do
    [ -n "${bay:-}" ] || continue
    n_present=$((n_present + 1))
    [ "$t" = "-" ] && continue
    n_readable=$((n_readable + 1))
    [ "$t" -gt "$maxd" ] && maxd=$t
  done <<EOF
$drives
EOF

  baseline_idx=1
  i=1
  for s in $SPEEDS; do
    [ "$s" -le "$BASELINE_RPM" ] && baseline_idx=$i
    i=$((i + 1))
  done

  # Degrees above each input's OWN threshold; the more urgent one wins.
  sb=0; sd=0
  [ -n "$board_t" ] && sb=$(steps_for "$board_t" "$BOARD_ESCALATE_C")
  [ "$n_readable" -gt 0 ] && sd=$(steps_for "$maxd" "$DRIVE_ESCALATE_C")
  steps=$sb
  [ "$sd" -gt "$steps" ] && steps=$sd

  if [ -z "$board_t" ] && [ "$n_readable" -eq 0 ] && [ "$n_present" -gt 0 ]; then
    # Drives are fitted and nothing at all can be read. No evidence the box is
    # cool, so assume it is not.
    log "WARNING: no readable temperature (board or $n_present drive(s)) - full speed"
    want=$NSPEEDS
    escalated=1
  elif [ -z "$board_t" ] && [ "$n_present" -eq 0 ]; then
    # Empty chassis and no board sensor: nothing to cool, nothing to go on.
    want=$baseline_idx
    escalated=0
  elif [ "$steps" -gt 0 ]; then
    want=$(( baseline_idx + steps ))
    [ "$want" -gt "$NSPEEDS" ] && want=$NSPEEDS
    escalated=1
  elif [ "$escalated" -eq 1 ] &&
       { { [ -n "$board_t" ] && [ "$board_t" -ge $(( BOARD_ESCALATE_C - HYST_C )) ]; } ||
         { [ "$n_readable" -gt 0 ] && [ "$maxd" -ge $(( DRIVE_ESCALATE_C - HYST_C )) ]; }; }; then
    # Still inside the hysteresis band on at least one input: hold, do not hunt.
    want=$idx
  else
    want=$baseline_idx
    escalated=0
  fi

  # The baseline is a floor.
  [ "$want" -lt "$baseline_idx" ] && want=$baseline_idx

  idx=$want
  rpm=$(nth "$idx" "$SPEEDS")

  if [ "$rpm" != "$last_written" ]; then
    if echo "$rpm" > "$fan" 2>/dev/null; then
      last_written=$rpm
    else
      log "WARNING: failed to write $rpm to $fan"
    fi
  fi

  # Log on a change of speed OR of what we can see. Logging only on speed change
  # was actively misleading: this board's SATA drives can take ~110 s to
  # enumerate (ata3 "link is slow to respond", then SRST failed), so the first
  # poll is routinely blind and prints "(0/0)". If the speed then never changes -
  # which it does not, since baseline covers both cases - that stale line stays
  # the last word for as long as the box is up, and the log looks current while
  # being wrong. Board temperature is deliberately NOT part of the key, or every
  # poll would log.
  state="$rpm|$n_readable/$n_present"
  if [ "$state" != "$last_state" ]; then
    log "board ${board_t:-?}C, drives max ${maxd}C ($n_readable/$n_present) -> ${rpm} rpm"
    last_state=$state
  fi

  # Front-panel status lamp: orange if anything is at or above its warn level,
  # or if drives are fitted and none can be read.
  if { [ "$n_present" -gt 0 ] && [ "$n_readable" -eq 0 ]; } ||
     { [ -n "$board_t" ] && [ "$board_t" -ge "$BOARD_WARN_C" ]; } ||
     { [ "$n_readable" -gt 0 ] && [ "$maxd" -ge "$DRIVE_WARN_C" ]; }; then
    mcu_set ';'
  else
    mcu_set 8
  fi

  update_leds "$drives"
  sleep "$POLL"
done
