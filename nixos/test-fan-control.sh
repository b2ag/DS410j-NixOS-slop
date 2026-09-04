#!/usr/bin/env bash
# Exercise ds410j-fan-control.sh against a fake sysfs tree.
#
# The board is not always to hand, so the temperature -> speed logic, the
# hysteresis and the fail-safe are worth checking on the build host instead.
# (This comment used to say every reboot needs a human to power cycle. Warm
# reboot works now - PORTING.md 3.3 - but running the logic on the host is still
# the faster loop.)
#
# KNOWN FLAKE, unresolved: one run in roughly thirteen has reported
# "54 passed, 1 failed" (seen once on 2026-09-04, then twelve consecutive clean
# runs). Which assertion failed was not captured - only the summary line - so
# there is nothing to fix yet. If you see it, keep the full output: that is the
# missing evidence. Suspect the parts that race, i.e. the daemon runs that poll a
# background process rather than the pure arithmetic checks.
set -uo pipefail
cd "$(dirname "$0")"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

# fake_tree <bay:temp_millidegrees|-> ...
# "-" means the drive is present but its sensor cannot be read.
fake_tree() {
  rm -rf "$ROOT/sys"
  mkdir -p "$ROOT/sys/class/hwmon/hwmon0" "$ROOT/sys/block" "$ROOT/sys/class/leds"
  echo gpio_fan > "$ROOT/sys/class/hwmon/hwmon0/name"
  echo 3300     > "$ROOT/sys/class/hwmon/hwmon0/fan1_target"
  # Board sensor. BOARD=none omits it entirely, to test the fallback path.
  if [ "${BOARD:-40000}" != none ]; then
    mkdir -p "$ROOT/sys/class/hwmon/hwmon9"
    echo lm75b            > "$ROOT/sys/class/hwmon/hwmon9/name"
    echo "${BOARD:-40000}" > "$ROOT/sys/class/hwmon/hwmon9/temp1_input"
  fi
  for bay in 1 2 3 4; do
    for c in green amber; do
      mkdir -p "$ROOT/sys/class/leds/synology:$c:hdd$bay"
      echo 0 > "$ROOT/sys/class/leds/synology:$c:hdd$bay/brightness"
    done
  done
  # The USB boot stick: a real sd* with no ataN in its path, must be ignored.
  mkdir -p "$ROOT/sys/devices/usb1/host0/target0:0:0/0:0:0:0"
  mkdir -p "$ROOT/sys/block/sda"
  ln -s ../../devices/usb1/host0/target0:0:0/0:0:0:0 "$ROOT/sys/block/sda/device"

  local letter=b
  for spec in "$@"; do
    local bay=${spec%%:*} milli=${spec##*:}
    local dev="$ROOT/sys/devices/pci/ata$bay/host$bay/target$bay:0:0/$bay:0:0:0"
    mkdir -p "$dev"
    mkdir -p "$ROOT/sys/block/sd$letter"
    ln -s "../../devices/pci/ata$bay/host$bay/target$bay:0:0/$bay:0:0:0" \
          "$ROOT/sys/block/sd$letter/device"
    if [ "$milli" != "-" ]; then
      mkdir -p "$dev/hwmon/hwmon$bay"
      echo "$milli" > "$dev/hwmon/hwmon$bay/temp1_input"
    fi
    letter=$(echo "$letter" | tr 'b-y' 'c-z')
  done
}

# run_once -> prints the rpm written to the fan
run_once() {
  SYSROOT="$ROOT" POLL=0 BASELINE_RPM="${BASE:-2200}" BOARD_ESCALATE_C=55 timeout 10 sh ./ds410j-fan-control.sh > "$ROOT/log" 2>&1 &
  local pid=$!
  # one pass is enough; POLL=0 makes it spin, so stop it quickly
  sleep 1
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$ROOT/sys/class/hwmon/hwmon0/fan1_target"
}

check() { # check <what> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok    %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

led() { cat "$ROOT/sys/class/leds/synology:$1:hdd$2/brightness"; }

echo "baseline: quiet until the escalation threshold"
# Defaults: baseline 2200, escalate at 50C, one step per 3C, cap 4200.
fake_tree 2:30000 4:28000 ; check "30C                  -> 2200 (baseline)" 2200 "$(run_once)"
fake_tree 2:37000          ; check "37C                  -> 2200 (baseline)" 2200 "$(run_once)"
fake_tree 2:47000          ; check "47C                  -> 2200 (baseline)" 2200 "$(run_once)"
fake_tree 2:49000          ; check "49C, just below      -> 2200 (baseline)" 2200 "$(run_once)"

echo
echo "escalation above the threshold"
fake_tree 2:50000          ; check "50C, first step      -> 2500" 2500 "$(run_once)"
fake_tree 2:53000          ; check "53C, second step     -> 3000" 3000 "$(run_once)"
fake_tree 2:56000          ; check "56C, third step      -> 3300" 3300 "$(run_once)"
fake_tree 2:80000          ; check "80C, capped          -> 4200" 4200 "$(run_once)"
fake_tree 2:30000 4:53000  ; check "hottest drive wins   -> 3000" 3000 "$(run_once)"

echo
echo "baseline is a floor, and is configurable"
fake_tree 2:30000
check "BASELINE_RPM=3300 at 30C -> 3300" 3300 "$(BASE=3300 run_once)"
check "BASELINE_RPM=3300 at 30C never drops below" 3300 "$(BASE=3300 run_once)"
fake_tree 2:50000
check "BASELINE_RPM=3300 at 50C steps up from there -> 3700" 3700 "$(BASE=3300 run_once)"

echo
echo "board sensor drives the fan too (own threshold: 55C)"
# The board idles ~46C, which is why it cannot share the drives' 50C threshold -
# it would sit escalated permanently. Each input is measured against its own.
BOARD=46000 fake_tree 2:30000 ; check "board 46C (idle)     -> 2200 baseline" 2200 "$(BOARD=46000 run_once)"
BOARD=54000 fake_tree 2:30000 ; check "board 54C just under -> 2200 baseline" 2200 "$(BOARD=54000 run_once)"
BOARD=55000 fake_tree 2:30000 ; check "board 55C first step -> 2500" 2500 "$(BOARD=55000 run_once)"
BOARD=58000 fake_tree 2:30000 ; check "board 58C           -> 3000" 3000 "$(BOARD=58000 run_once)"
BOARD=70000 fake_tree 2:30000 ; check "board 70C           -> 4200" 4200 "$(BOARD=70000 run_once)"

echo
echo "the more urgent input wins"
# board 58C = 2 steps above its threshold; drive 50C = 1 step above its own.
BOARD=58000 fake_tree 2:50000 ; check "board 58C beats drive 50C -> 3000" 3000 "$(BOARD=58000 run_once)"
# drive 56C = 3 steps; board 46C = 0.
BOARD=46000 fake_tree 2:56000 ; check "drive 56C beats cool board -> 3300" 3300 "$(BOARD=46000 run_once)"

echo
echo "degraded sensors"
# Deliberate change of behaviour: a present drive whose temperature cannot be
# read no longer forces full speed, PROVIDED the board sensor is readable and
# cool. Some drives genuinely do not report a temperature ("will avoid using SCT
# for temperature monitoring" appears in dmesg here), and roaring forever over
# one such drive would be wrong. The board sensor is the better proxy for whether
# cooling is adequate.
BOARD=40000 fake_tree 2:- 4:-  ; check "unreadable drives + cool board -> baseline" 2200 "$(BOARD=40000 run_once)"
BOARD=70000 fake_tree 2:- 4:-  ; check "unreadable drives + HOT board  -> 4200"    4200 "$(BOARD=70000 run_once)"
# With no board sensor at all, the old fail-safe still applies.
BOARD=none  fake_tree 2:- 4:-  ; check "unreadable drives + NO board   -> 4200"    4200 "$(BOARD=none run_once)"
BOARD=none  fake_tree 2:30000  ; check "no board sensor, drives fine   -> 2200"    2200 "$(BOARD=none run_once)"
echo
echo "fail-safe and empty chassis"
fake_tree                  ; check "no drives at all          -> 2200" 2200 "$(run_once)"
fake_tree 2:- 4:52000      ; check "one readable is enough    -> 2500" 2500 "$(run_once)"

echo
echo "never selects fan-off"
fake_tree 2:1000           ; check "1C, absurdly cold  -> 2200 not 0" 2200 "$(run_once)"

echo
echo "bay LEDs"
fake_tree 2:30000 4:60000
run_once > /dev/null
check "bay1 empty, green off"  0 "$(led green 1)"
check "bay2 present, green on" 1 "$(led green 2)"
check "bay2 cool, amber off"   0 "$(led amber 2)"
check "bay4 present but HOT, green cleared" 0 "$(led green 4)"   # not both: see update_leds
check "bay4 at 60C, amber on"  1 "$(led amber 4)"

echo
echo "no gpio_fan device"
fake_tree 2:30000
rm -rf "$ROOT/sys/class/hwmon/hwmon0"
SYSROOT="$ROOT" sh ./ds410j-fan-control.sh > "$ROOT/log" 2>&1
rc=$?
check "exits non-zero"          1 "$rc"
grep -q "not touching it" "$ROOT/log" \
  && { echo "  ok    says it is leaving the fan alone"; pass=$((pass+1)); } \
  || { echo "  FAIL  expected the leave-it-alone message"; fail=$((fail+1)); }


echo
echo "hysteresis across polls"
# Escalation starts at 50C, so coming back down to baseline needs the hottest
# drive below 50-HYST = 47C. 48C must therefore hold the escalated speed and
# 46C must drop to baseline. Needs a daemon alive across several polls.
fake_tree 2:60000
SYSROOT="$ROOT" POLL=1 sh ./ds410j-fan-control.sh > "$ROOT/log" 2>&1 &
bg=$!
settle() { local want=$1 n=0; while [ $n -lt 30 ]; do
    [ "$(cat "$ROOT/sys/class/hwmon/hwmon0/fan1_target")" = "$want" ] && return 0
    sleep 0.2; n=$((n+1)); done; return 1; }
T="$ROOT/sys/devices/pci/ata2/host2/target2:0:0/2:0:0:0/hwmon/hwmon2/temp1_input"
settle 3700 && { echo "  ok    60C settles at 3700"; pass=$((pass+1)); } \
             || { echo "  FAIL  60C never reached 3700"; fail=$((fail+1)); }
echo 48000 > "$T"; sleep 3
check "48C holds (inside the band)" 3700 "$(cat "$ROOT/sys/class/hwmon/hwmon0/fan1_target")"
echo 46000 > "$T"
settle 2200 && { echo "  ok    46C returns to baseline 2200"; pass=$((pass+1)); } \
             || { echo "  FAIL  46C did not return to baseline"; fail=$((fail+1)); }
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
echo
echo "front-panel status lamp"
# A stub MCU helper that just records the codes it is handed.
cat > "$ROOT/fakemcu" <<'STUB'
#!/bin/sh
echo "$1" >> "$MCULOG"
STUB
chmod +x "$ROOT/fakemcu"
mcu_run() {
  : > "$ROOT/mcucodes"
  MCULOG="$ROOT/mcucodes" MCU="$ROOT/fakemcu" SYSROOT="$ROOT" POLL=0 \
    timeout 10 sh ./ds410j-fan-control.sh > "$ROOT/log" 2>&1 &
  local pid=$!
  sleep 1
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  head -1 "$ROOT/mcucodes"
}
fake_tree 2:30000 4:28000 ; check "all cool          -> 8 (green)"  8   "$(mcu_run)"
fake_tree 2:60000          ; check "60C, over WARN    -> ; (orange)" ";" "$(mcu_run)"
fake_tree 2:- 4:-          ; check "present, no sensor-> ; (orange)" ";" "$(mcu_run)"

# The helper must never be able to power the box off, whatever it is handed.
echo
echo "MCU helper allowlist"
for bad in 1 t x "" 0; do
  if MCU_DEV=/dev/null sh ./ds410j-mcu.sh "$bad" >/dev/null 2>&1; then
    echo "  FAIL  helper accepted '$bad'"; fail=$((fail+1))
  else
    echo "  ok    helper refused '$bad'"; pass=$((pass+1))
  fi
done

# The driver's debugfs interface is the preferred transport once synology-mcu
# owns UART1 and /dev/ttyS1 is gone. A good code must go there in preference to
# the character device, and the allowlist must still be applied first.
echo
echo "MCU helper transport"
: > "$ROOT/dbgsend"
MCU_DBG="$ROOT/dbgsend" MCU_DEV=/dev/null sh ./ds410j-mcu.sh 8 >/dev/null 2>&1
check "good code reaches debugfs send" 8 "$(cat "$ROOT/dbgsend")"

: > "$ROOT/dbgsend"
if MCU_DBG="$ROOT/dbgsend" MCU_DEV=/dev/null sh ./ds410j-mcu.sh 1 >/dev/null 2>&1; then
  echo "  FAIL  poweroff reached debugfs send"; fail=$((fail+1))
else
  echo "  ok    poweroff refused before any transport"; pass=$((pass+1))
fi
check "nothing written for a refused code" "" "$(cat "$ROOT/dbgsend")"

# No driver and no tty is the ordinary case on a build host: succeed silently
# rather than failing a service.
if MCU_DBG="$ROOT/nonexistent" MCU_DEV="$ROOT/nonexistent" \
     sh ./ds410j-mcu.sh 8 >/dev/null 2>&1; then
  echo "  ok    absent MCU is not an error"; pass=$((pass+1))
else
  echo "  FAIL  absent MCU treated as an error"; fail=$((fail+1))
fi

echo
echo "bay LED pins are mutually exclusive"
# The pins drive one anti-parallel bi-colour LED: equal levels = dark. A hot
# drive must therefore show amber with green CLEARED, never both.
fake_tree 1:60000 3:30000
run_once > /dev/null
check "hot bay: amber on"        1 "$(led amber 1)"
check "hot bay: green CLEARED"   0 "$(led green 1)"
check "cool bay: green on"       1 "$(led green 3)"
check "cool bay: amber off"      0 "$(led amber 3)"
check "empty bay: both dark (g)" 0 "$(led green 2)"
check "empty bay: both dark (a)" 0 "$(led amber 2)"

echo
echo "logging reflects what changed"
# Speed-only logging hid the fact that drives had appeared: the boot-time
# "(0/0)" line stayed the last word because baseline covers both cases.
cat > "$ROOT/runlog" <<'STUB'
STUB
BOARD=40000 fake_tree                       # no drives
SYSROOT="$ROOT" POLL=1 BOARD_ESCALATE_C=55 sh ./ds410j-fan-control.sh > "$ROOT/log2" 2>&1 &
lg=$!
sleep 2
# drives appear late, exactly as they do on the real board (~110s to enumerate)
BOARD=40000 fake_tree 1:40000 3:38000
sleep 4
kill "$lg" 2>/dev/null; wait "$lg" 2>/dev/null
if grep -q "(0/0)" "$ROOT/log2" && grep -q "(2/2)" "$ROOT/log2"; then
  echo "  ok    logged both the blind first poll and the drives appearing"; pass=$((pass+1))
else
  echo "  FAIL  expected both (0/0) and (2/2) lines; got:"; sed 's/^/        /' "$ROOT/log2"; fail=$((fail+1))
fi
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
