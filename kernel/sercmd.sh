#!/usr/bin/env bash
# Send a command to the DS410j serial console and print only the new output.
# usage: sercmd.sh "<command>" [wait_seconds]
SERIAL_DEV=${SERIAL_DEV:-/dev/ttyUSB0}
LOG=/src/kernel/logs/serial.log
WAIT=${2:-2}
before=$(stat -c %s "$LOG")
printf '%s\r' "$1" > "$SERIAL_DEV"
sleep "$WAIT"
after=$(stat -c %s "$LOG")
dd if="$LOG" bs=1 skip="$before" count=$((after-before)) 2>/dev/null | tr -d '\r'
