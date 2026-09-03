#!/usr/bin/env bash
# Serial logger for the DS410j console.
# Device is overridable: the host<->VM handover has changed it once already
# (/dev/ttyS1 -> /dev/ttyUSB0 when the adapter moved to USB passthrough).
SERIAL_DEV=${SERIAL_DEV:-/dev/ttyUSB0}
LOG=/src/kernel/logs/serial.log
exec 0</dev/null
exec cat "$SERIAL_DEV" >> "$LOG" 2>/dev/null
