#!/bin/sh
# Device-side bench tool for the DS410j: drive the fan and the LEDs by hand.
#
# Unlike the other scripts in this directory this one runs ON the DS410j, not on
# the host. Copy it over with install-bench.sh, then run it from a serial or ssh
# root shell.
#
# The fan is a 3-bit GPIO speed select on GPIO0 15/16/17 (PORTING.md 5.3), and
# ctrl 0 means OFF, so this tool refuses to select 0 unless you say --force.
#
# It drives the pins through libgpiod rather than the gpio-fan driver on purpose:
# it has to work on a kernel where CONFIG_SENSORS_GPIO_FAN is not set, which is
# exactly the kernel that made this tool necessary.

GPIOD=${GPIOD:-/root/gpiod}
export LD_LIBRARY_PATH="$GPIOD"
GPIOSET="$GPIOD/gpioset"
GPIOGET="$GPIOD/gpioget"

FAN_B0=15; FAN_B1=16; FAN_B2=17

# The upstream speed-map from kirkwood-synology.dtsi, ctrl -> claimed rpm.
# Note it is NOT monotonic in ctrl: 4 is 3000 rpm, below 3's 3300.
rpm_for() {
  case "$1" in
    0) echo "0 (OFF)" ;;  1) echo 2200 ;;  2) echo 2500 ;;  3) echo 3300 ;;
    4) echo 3000 ;;       5) echo 3700 ;;  6) echo 3800 ;;  7) echo 4200 ;;
    *) echo "?" ;;
  esac
}

# Since CONFIG_SENSORS_GPIO_FAN was fixed, the gpio-fan driver owns pins 15/16/17
# and libgpiod cannot read them - they come back "Device or resource busy". That
# is the healthy state. Prefer the hwmon interface and fall back to raw GPIO for
# the older kernels this tool was written against.
fan_hwmon() {
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    read -r n < "$h/name" || continue
    [ "$n" = "gpio_fan" ] && { echo "$h"; return 0; }
  done
  return 1
}

fan_get() {
  if h=$(fan_hwmon); then
    echo "via gpio-fan hwmon ($h)"
    echo "  fan1_target = $(cat "$h/fan1_target" 2>/dev/null) rpm"
    echo "  fan1_input  = $(cat "$h/fan1_input" 2>/dev/null) rpm"
    return 0
  fi
  bits=$("$GPIOGET" --as-is --numeric -c gpiochip0 $FAN_B0 $FAN_B1 $FAN_B2) || return 1
  b0=$(echo "$bits" | cut -d' ' -f1)
  b1=$(echo "$bits" | cut -d' ' -f2)
  b2=$(echo "$bits" | cut -d' ' -f3)
  ctrl=$(( b0 + 2*b1 + 4*b2 ))
  echo "via raw GPIO (no gpio-fan driver bound)"
  echo "  ctrl=$ctrl  (gpio15=$b0 gpio16=$b1 gpio17=$b2)  claimed $(rpm_for $ctrl) rpm"
}

fan_set() {
  c=$1
  case "$c" in [0-7]) ;; *) echo "fan set: ctrl must be 0-7" >&2; return 1 ;; esac
  if [ "$c" = 0 ] && [ "$2" != "--force" ]; then
    echo "fan set: ctrl 0 switches the fans OFF. Re-run with --force if you mean it." >&2
    return 1
  fi
  b0=$(( c & 1 )); b1=$(( (c >> 1) & 1 )); b2=$(( (c >> 2) & 1 ))
  # gpioset holds the lines until it exits; the mvebu pins keep their value
  # after release (verified on this board), so a 1 s hold is enough to latch.
  timeout 1 "$GPIOSET" -c gpiochip0 $FAN_B0=$b0 $FAN_B1=$b1 $FAN_B2=$b2
  echo "ctrl=$c  claimed $(rpm_for $c) rpm"
}

fan_sweep() {
  hold=${1:-8}
  for c in 1 2 4 3 5 6 7; do
    echo "$(date +%H:%M:%S)  ctrl=$c  claimed $(rpm_for $c) rpm"
    b0=$(( c & 1 )); b1=$(( (c >> 1) & 1 )); b2=$(( (c >> 2) & 1 ))
    timeout "$hold" "$GPIOSET" -c gpiochip0 $FAN_B0=$b0 $FAN_B1=$b1 $FAN_B2=$b2
  done
  echo "$(date +%H:%M:%S)  restoring ctrl=3"
  fan_set 3 >/dev/null
  fan_get
}

# Step through the eight speeds one at a time, waiting for you between each, so
# you can listen for as long as you like. This is the one that gives a usable
# answer; the timed sweep goes past too fast to judge.
fan_step() {
  echo "Enter a ctrl value 0-7 to select it, blank for the next one up, q to quit."
  echo "0 is fans-OFF and is applied here without further confirmation."
  echo "Each line shows the pins read back, so what you see is what the hardware has."
  echo "Ends by restoring ctrl=3."
  c=1
  while : ; do
    fan_set "$c" --force >/dev/null || echo "  !! failed to set ctrl=$c"
    printf '  ctrl=%-2s claimed %-9s rpm   pins now: %s   [enter=next, 0-7, q] ' \
      "$c" "$(rpm_for $c)" \
      "$("$GPIOGET" --as-is --numeric -c gpiochip0 $FAN_B0 $FAN_B1 $FAN_B2)"
    read -r ans
    case "$ans" in
      q|Q) break ;;
      "")  c=$(( (c + 1) % 8 )); [ "$c" = 0 ] && c=1 ;;
      [0-7]) c=$ans ;;
      *) echo "  ? 0-7, enter, or q" ;;
    esac
  done
  echo "restoring ctrl=3"
  fan_set 3
}

led_list() {
  for l in /sys/class/leds/*/; do
    [ -d "$l" ] || continue
    printf '%-24s brightness=%s trigger=%s\n' "$(basename "$l")" \
      "$(cat "$l/brightness")" \
      "$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$l/trigger")"
  done
}

led_set() {
  l=/sys/class/leds/$1
  [ -d "$l" ] || { echo "led set: no such LED: $1" >&2; return 1; }
  echo "$2" > "$l/brightness" && echo "$1 -> $2"
}

led_all() {
  v=$1
  for l in /sys/class/leds/*/; do echo "$v" > "$l/brightness" 2>/dev/null; done
  echo "all LEDs -> $v"
}

# Light one LED at a time and wait, so you can write down which physical lamp
# each DT name actually corresponds to. On the DS410j we expect most of these to
# do nothing: synobios drives the HDD LEDs through an external chip, not GPIO.
led_walk() {
  led_all 0 >/dev/null
  for l in /sys/class/leds/*/; do
    [ -d "$l" ] || continue
    n=$(basename "$l")
    echo 1 > "$l/brightness" 2>/dev/null
    printf '  %-24s is ON   [enter=next, q=quit] ' "$n"
    read -r ans
    echo 0 > "$l/brightness" 2>/dev/null
    case "$ans" in q|Q) break ;; esac
  done
  led_all 0
}

#### MCU on UART1 #############################################################
# The board microcontroller lives on /dev/ttyS1 at 9600 8N1 and takes single
# ASCII characters. It owns the front-panel status and power lamps and the power
# rail; mainline's qnap-poweroff.c powers the box down by sending it '1'.
#
# Two characters are refused unless you pass --force:
#   '1'  powers the box off immediately (qnap-poweroff.c)
#   't'  unidentified, appears in DSM's syno_poweroff_task shutdown path
#
# Every character is written to the log BEFORE it is sent, and the log is synced.
# That ordering is the point: if a code kills the box, the log still names it.

MCU_DEV=${MCU_DEV:-/dev/ttyS1}
MCU_LOG=${MCU_LOG:-/root/mcu-map.txt}
# /root is a tmpfs on the read-only-root image, so this log does NOT survive a
# reboot. Every send is also echoed to the serial console, which the host records
# persistently in kernel/logs/serial.log - grep it for "MCU-SEND".

mcu_desc() { # documented meaning, or empty
  case "$1" in
    1) echo "POWER OFF (qnap-poweroff.c)" ;;
    2) echo "buzzer, short beep" ;;
    3) echo "buzzer, long beep" ;;
    4) echo "power LED steady" ;;
    5) echo "power LED blinking" ;;
    6) echo "power LED off" ;;
    7) echo "status LED off" ;;
    8) echo "status LED green, static" ;;
    9) echo "status LED green, blink" ;;
    :) echo "status LED orange, static" ;;
    \;) echo "status LED orange, blink" ;;
    t) echo "UNKNOWN, used in DSM shutdown" ;;
    k|l) echo "wake-on-lan (libsynosdk), not an LED" ;;
    *) echo "" ;;
  esac
}

mcu_dangerous() {
  case "$1" in 1|t) return 0 ;; *) return 1 ;; esac
}

mcu_init() {
  stty -F "$MCU_DEV" 9600 cs8 -cstopb -parenb raw -echo 2>/dev/null || {
    echo "mcu: cannot configure $MCU_DEV" >&2; return 1; }
}

mcu_send() { # mcu_send <char> [--force]
  c=$1
  if mcu_dangerous "$c" && [ "${2:-}" != "--force" ]; then
    echo "mcu: refusing '$c' - $(mcu_desc "$c")." >&2
    echo "     Re-run with --force if you really mean it." >&2
    return 1
  fi
  mcu_init || return 1
  _line="$(date +%H:%M:%S)  sent [$c] 0x$(printf '%02x' "'$c")  $(mcu_desc "$c")"
  # Log BEFORE sending, then sync: if a code kills the box, the record survives.
  printf '%s\n' "$_line" >> "$MCU_LOG"
  sync
  # ...and echo it to the serial console as well. /root is a tmpfs on this image,
  # so MCU_LOG dies at the next reboot - which already cost us the record of
  # whatever enabled power-on-at-AC-restore (PORTING.md 3.3). The console is
  # captured on the HOST by kernel/serlog.sh into logs/serial.log, which is the
  # only genuinely persistent sink this box has.
  printf 'MCU-SEND %s\n' "$_line" > /dev/console 2>/dev/null || true
  printf '%s' "$c" > "$MCU_DEV"
}

# Walk the documented codes, waiting at each so you can confirm them yourself.
mcu_known() {
  mcu_init || return 1
  echo "Confirming the documented status-LED codes. Nothing here is dangerous."
  for c in 8 9 : ';' 7; do
    mcu_send "$c" >/dev/null 2>&1
    printf '  sent [%s]  expect: %-28s [enter] ' "$c" "$(mcu_desc "$c")"
    read -r _
  done
  echo "done - status LED left off. Log: $MCU_LOG"
}

# Step through printable ASCII one character at a time, recording what you see.
# Notes are appended immediately so nothing is lost if the box drops.
mcu_probe() {
  from=${1:-0x20}; to=${2:-0x7e}
  f=$(printf '%d' "$from"); t=$(printf '%d' "$to")
  cat <<WARN
About to step through ASCII $from..$to on $MCU_DEV, one character at a time.
'1' and 't' are skipped. Everything else is UNIDENTIFIED: a character may power
the box off, and in principle could do something persistent to the MCU.
Notes go to $MCU_LOG as you type them.
WARN
  printf 'Type YES to continue: '; read -r ans
  [ "$ans" = "YES" ] || { echo "aborted"; return 1; }
  mcu_init || return 1
  echo "== probe $from..$to $(date +%F' '%H:%M:%S)" >> "$MCU_LOG"

  n=$f
  while [ "$n" -le "$t" ]; do
    c=$(printf "\\$(printf '%03o' "$n")")
    if mcu_dangerous "$c"; then
      printf '  0x%02x [%s] SKIPPED - %s\n' "$n" "$c" "$(mcu_desc "$c")"
      n=$((n + 1)); continue
    fi
    known=$(mcu_desc "$c")
    mcu_send "$c" >/dev/null 2>&1
    printf '  0x%02x [%s] %s\n     what happened? (enter=nothing, q=quit) ' \
      "$n" "$c" "${known:+  known: $known}"
    read -r note || break
    case "$note" in
      q|Q) echo "== stopped at 0x$(printf '%02x' $n)" >> "$MCU_LOG"; break ;;
      "") note="(nothing observed)" ;;
    esac
    printf '     -> %s\n' "$note" >> "$MCU_LOG"
    sync
    n=$((n + 1))
  done
  echo "log: $MCU_LOG"
}

# Walk one bay's two pins through all four combinations, waiting at each.
# These are not two independent lamps: they drive one bi-colour LED wired
# anti-parallel, so 1/0 and 0/1 give the two colours and 0/0 and 1/1 both give
# darkness. This is the command that shows that.
led_bay() {
  b=${1:-1}
  g="/sys/class/leds/synology:green:hdd$b/brightness"
  a="/sys/class/leds/synology:amber:hdd$b/brightness"
  [ -w "$g" ] && [ -w "$a" ] || { echo "led bay: no such bay: $b" >&2; return 1; }
  echo "Watch bay $b only. The fan daemon re-asserts these every 30s, so stop it"
  echo "first if a step seems to undo itself:  systemctl stop ds410j-fan-control"
  for pair in "1 0" "0 1" "1 1" "0 0"; do
    set -- $pair
    echo "$1" > "$g"; echo "$2" > "$a"
    case "$pair" in
      "1 0") exp="AMBER (works on an empty bay too)" ;;
      "0 1") exp="GREEN, but only if this bay has a drive" ;;
      *)     exp="DARK (equal levels = no potential across the LED)" ;;
    esac
    printf '  green_gpio=%s amber_gpio=%s  expect: %-46s [enter] ' "$1" "$2" "$exp"
    read -r _
  done
  echo 0 > "$g"; echo 0 > "$a"
  echo "done - bay $b left dark"
}

#### Finding an unknown button ################################################
# There is no gpio-keys node anywhere in kirkwood-synology.dtsi, so Linux has no
# input device and no idea the front-panel buttons exist. Writing that node needs
# the GPIO number, and nothing in mainline or in DSM's binaries states it. This
# finds it by observation: snapshot every readable line, hold the button, snapshot
# again, and report what moved.
#
# Lines already claimed by a driver (the fan, the bay LEDs) come back busy and are
# skipped. Everything is read with --as-is, which never changes a line's
# direction - reading must not be able to disturb the fan.

# Discover which lines are readable at all. Done once, up front, with no button
# involved - it is slow (one process per line) and there is no hurry here.
gpio_readable() { # gpio_readable <chip>  -> space separated offsets
  n=$("$GPIOD/gpioinfo" -c "gpiochip$1" 2>/dev/null | head -1 | sed 's/.*- \([0-9]*\) lines.*/\1/')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  out=""
  i=0
  while [ "$i" -lt "$n" ]; do
    if "$GPIOGET" --as-is --numeric -c "gpiochip$1" "$i" >/dev/null 2>&1; then
      out="$out $i"
    fi
    i=$((i + 1))
  done
  echo "$out"
}

button_hunt() {
  export LD_LIBRARY_PATH="$GPIOD"
  echo "Finding readable lines (claimed ones - fan, bay LEDs - are skipped)..."
  L0=$(gpio_readable 0); L1=$(gpio_readable 1)
  echo "  gpiochip0:$L0"
  echo "  gpiochip1:$L1"
  echo
  # One gpioget call per chip, so the sample is a single fast read. That matters:
  # the button has to be held while it happens, and a LONG hold may make the MCU
  # cut power (PORTING.md 7.1). Keep the hold to a second or so.
  # shellcheck disable=SC2086
  snap() { "$GPIOGET" --as-is --numeric -c gpiochip0 $L0 2>/dev/null; "$GPIOGET" --as-is --numeric -c gpiochip1 $L1 2>/dev/null; }
  before=$(snap)
  echo "Baseline taken. Now press and hold the button, and while STILL HOLDING"
  echo "press enter. Do not hold for long - a few seconds at most."
  printf '  [enter while held] '
  read -r _
  after=$(snap)

  echo
  changed=0
  set -- $L0
  n0=$#
  i=1
  for off in $L0 $L1; do
    if [ "$i" -le "$n0" ]; then chip=0; else chip=1; fi
    b=$(echo "$before" | tr ' ' '\n' | sed -n "${i}p")
    a=$(echo "$after"  | tr ' ' '\n' | sed -n "${i}p")
    if [ "$b" != "$a" ]; then
      echo "  *** gpiochip$chip line $off : $b -> $a   <== candidate"
      changed=1
    fi
    i=$((i + 1))
  done
  [ "$changed" = 0 ] && {
    echo "  nothing changed."
    echo "  Either the button is not wired to a SoC GPIO at all (it may go only to"
    echo "  the microcontroller), or its line is one of the claimed ones, or the"
    echo "  press did not overlap the sample. Worth one retry before concluding."
  }
}
# Live edge watch: catches a momentary press that a before/after snapshot can
# miss. Requests lines as INPUT, so it deliberately refuses the fan pins.
button_watch() {
  export LD_LIBRARY_PATH="$GPIOD"
  secs=${1:-20}
  echo "Watching gpiochip0 for edges for ${secs}s - press the button a few times."
  echo "(fan pins 15/16/17 excluded; they must never be flipped to input)"
  lines=""
  for i in $(seq 0 31); do
    case $i in 15|16|17) continue ;; esac
    lines="$lines $i"
  done
  # shellcheck disable=SC2086
  timeout "$secs" "$GPIOD/gpiomon" --edges=both -c gpiochip0 $lines 2>&1 | head -40
  echo "done"
}

# Listen for bytes FROM the microcontroller.
#
# An earlier passive test saw rx:0 and concluded the MCU never transmits. That
# test was wrong in an important way: nobody pressed a button during it. DSM's
# scemd contains the string "can't get ttyS1 data", so it plainly does read this
# port, and the front-panel buttons are not on any SoC GPIO (button hunt found
# nothing) and do not power the box off when held. The remaining explanation is
# that the MCU reports button presses up this line and the host decides what to
# do - which is also why synobios has a poll() entry point.
mcu_listen() {
  secs=${1:-30}
  mcu_init || return 1
  before=$(sed -n 's/^ *1:.*rx:\([0-9]*\).*/\1/p' /proc/tty/driver/serial)
  echo "Listening on $MCU_DEV for ${secs}s at 9600 8N1."
  echo "Press the POWER button, then the RESET button. Short presses are enough."
  echo "rx counter before: $before"
  timeout "$secs" cat "$MCU_DEV" > /tmp/.mcu-rx 2>/dev/null
  after=$(sed -n 's/^ *1:.*rx:\([0-9]*\).*/\1/p' /proc/tty/driver/serial)
  n=$(wc -c < /tmp/.mcu-rx)
  echo
  echo "rx counter after:  $after   (bytes captured: $n)"
  if [ "$n" -gt 0 ]; then
    echo "BYTES RECEIVED:"
    od -An -tx1c -v /tmp/.mcu-rx | sed 's/^/  /'
  elif [ "$after" != "$before" ]; then
    echo "The rx counter moved but nothing reached us - framing or baud is wrong."
  else
    echo "Nothing at all. The MCU really is silent, even on a button press."
  fi
  rm -f /tmp/.mcu-rx
}

# Send one command and listen for a reply.
#
# If the MCU never speaks unprompted, the next hypothesis is request/response:
# DSM's scemd carries the string "can't get ttyS1 data", which is a read that can
# fail - i.e. it asks and sometimes gets nothing. A command that reports button
# state would explain how DSM does a clean shutdown from a button that is on no
# SoC GPIO. Unmapped letters are the place to look.
mcu_query() { # mcu_query <char> [seconds]
  c=$1; secs=${2:-3}
  if mcu_dangerous "$c"; then
    echo "mcu query: refusing '$c' - $(mcu_desc "$c")" >&2; return 1
  fi
  mcu_init || return 1
  timeout "$secs" cat "$MCU_DEV" > /tmp/.mcu-q 2>/dev/null &
  cat_pid=$!
  sleep 1
  printf '%s' "$c" >> "$MCU_LOG" 2>/dev/null
  printf '%s' "$c" > "$MCU_DEV"
  wait "$cat_pid" 2>/dev/null
  n=$(wc -c < /tmp/.mcu-q)
  if [ "$n" -gt 0 ]; then
    echo "  [$c] -> $n byte(s) BACK:"
    od -An -tx1c -v /tmp/.mcu-q | sed 's/^/     /'
  else
    echo "  [$c] -> no reply"
  fi
  rm -f /tmp/.mcu-q
}

# Decode input events from gpio-keys and name the pin.
#
# struct input_event on 32-bit ARM is 16 bytes: sec(4) usec(4) type(2) code(2)
# value(4). od -tu2 -w16 gives eight u16 per line, so type is field 5, code is
# field 6, the low half of value is field 7. type 1 is EV_KEY, value 1 is press.
#
# Candidate keycodes are 600 + the GPIO number, so a press names its own pin.
button_events() {
  secs=${1:-30}
  dev=$(ls /dev/input/event* 2>/dev/null | head -1)
  if [ -z "$dev" ]; then
    echo "no /dev/input/event* - gpio-keys did not probe." >&2
    echo "check: dmesg | grep -i gpio-keys   and   cat /proc/bus/input/devices" >&2
    return 1
  fi
  echo "reading $dev for ${secs}s"
  echo "press the POWER button, then the RESET button."
  timeout "$secs" od -An -tu2 -w16 -v "$dev" | while read -r _ _ _ _ type code val _; do
    [ "$type" = "1" ] || continue
    if [ "$code" -ge 600 ] && [ "$code" -le 700 ]; then
      name="GPIO $((code - 600))"
    else
      name="keycode $code"
    fi
    if [ "$val" = "1" ]; then act="PRESS  "; else act="release"; fi
    echo "  $act  <-- $name"
  done
  echo "done"
}

usage() {
  cat <<USAGE
usage: ds410j-bench.sh <command>

  fan get              show the current 3-bit fan speed select
  fan set N [--force]  select ctrl N (0-7); 0 is OFF and needs --force
  fan sweep [secs]     walk 2200 -> 4200 rpm automatically, then restore 3300
  fan step             walk the speeds interactively, waiting for you at each

  led list             show every registered LED with its brightness and trigger
  led walk             light each LED in turn, waiting for you at each
  led set NAME 0|1     switch one named LED off or on
  led bay N            walk one bay's two pins through all four combinations

  button hunt          find which GPIO a front-panel button is on
  button watch [secs]  live edge watch (flips lines to input - see the source)
  button events [secs] decode gpio-keys presses and name the pin
  led all 0|1          switch every LED off or on

  mcu known            confirm the documented status-LED codes, waiting at each
  mcu send C [--force] send one character to the MCU (refuses '1' and 't')
  mcu probe [F] [T]    step through ASCII F..T, recording what you see
  mcu listen [secs]    listen for bytes FROM the MCU (press buttons while it runs)
  mcu query C [secs]   send C, then listen for a reply
  mcu map              print the probe log
USAGE
}

case "$1 $2" in
  "fan get")   fan_get ;;
  "fan set")   shift 2; fan_set "$@" ;;
  "fan sweep") fan_sweep "$3" ;;
  "fan step")  fan_step ;;
  "led list")  led_list ;;
  "led walk")  led_walk ;;
  "led set")   led_set "$3" "$4" ;;
  "led all")   led_all "$3" ;;
  "led bay")   led_bay "$3" ;;
  "mcu known") mcu_known ;;
  "mcu send")  mcu_send "$3" "${4:-}" ;;
  "mcu probe") mcu_probe "$3" "$4" ;;
  "mcu listen") mcu_listen "$3" ;;
  "mcu query")  mcu_query "$3" "$4" ;;
  "mcu map")   cat "${MCU_LOG:-/root/mcu-map.txt}" 2>/dev/null || echo "no log yet" ;;
  "button hunt")  button_hunt ;;
  "button watch") button_watch "$3" ;;
  "button events") button_events "$3" ;;
  *) usage; exit 1 ;;
esac
