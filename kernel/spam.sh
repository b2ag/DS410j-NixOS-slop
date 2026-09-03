#!/usr/bin/env bash
# Spam the serial line so U-Boot autoboot (bootdelay=3) gets interrupted
# whenever the board powers on. Sends spaces only, so nothing executes.
SERIAL_DEV=${SERIAL_DEV:-/dev/ttyUSB0}
DUR=${1:-240}
END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  printf " " > "$SERIAL_DEV"
  sleep 0.1
done
