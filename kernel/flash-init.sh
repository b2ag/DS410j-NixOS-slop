#!/bin/sh
# initramfs init for the DS410j USB-stick flasher (OPERATIONS.md, "Flashing the
# USB stick without a human").
#
# Runs entirely from RAM, so it can safely overwrite the very stick the box
# normally boots from. The image is STREAMED from HTTP straight to the block
# device - it is ~700 MB against 118 MB of RAM, so it can never be buffered.
#
# Why this is safe to get wrong: the two-stage bootloader chain lives in SPI
# flash, not on the stick (CLAUDE.md). A half-written stick does not brick
# anything - our U-Boot simply finds no bootflow, drops to its prompt, and this
# flasher can be TFTP-booted again. That is what makes an unattended reflash
# reasonable at all.
#
# What protects the DATA, which is a different question: the flasher kernel is
# built with PCI, ATA, SATA_MV and MTD switched off (flasher.nix), so the two
# 3 TB drives and the SPI flash are not merely left alone, they are unreachable.
# The checks below re-establish that from this side too, because a kernel
# rebuilt without those flags would put a 3 TB disk one probe race away from
# being the thing called /dev/sda.
#
# Everything is driven from the kernel command line so the payload can change
# without rebuilding this image:
#
#   flash.url=http://192.168.50.1:8080/ds410j-nixos.img
#   flash.sha256=<hex>          expected sha256 of the image (optional, wanted)
#   flash.size=<bytes>          image size, needed to read back exactly as much
#   flash.dev=auto              target; "auto" = the one USB disk (default)
#   flash.ip=192.168.50.60      static address for eth0
#   flash.mask=255.255.255.0
#   flash.reboot=1              restart via the MCU when done
#   flash.force=1               skip the USB-attachment check (you had better mean it)
set -u

/bin/busybox --install -s /bin
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null

# A failing wget in `wget | dd` would otherwise be invisible: without this the
# pipeline reports dd's status, and dd is perfectly happy to have been handed a
# truncated stream.
set -o pipefail 2>/dev/null || echo "[flash] warning: no pipefail; relying on the sha256 check"

say() { echo "[flash] $*"; }
die() {
  echo
  echo "[flash] FAILED: $*"
  echo "[flash] dropping to a shell; nothing further is written."
  exec /bin/sh
}

# /proc/cmdline word-by-word. The previous version used
# `sed 's/.*\bKEY=\([^ ]*\).*/\1/p'`, which does work - busybox sed supports \b
# (checked against busybox 1.37) - but the dots in the keys are regex wildcards,
# so `flash.url` also matches `flashXurl=...` (verified). Splitting on words
# instead needs no escaping and cannot match a key that was not written.
arg() { # arg <key> <default>
  for w in $(cat /proc/cmdline); do
    case "$w" in
      "$1="*) echo "${w#$1=}"; return 0 ;;
    esac
  done
  echo "$2"
}

# Is this block device behind a USB controller? The sysfs device link spells out
# the whole path, so a USB disk contains a /usbN/ hop and a SATA one does not.
is_usb() { # is_usb sda
  case "$(readlink -f /sys/class/block/$1/device 2>/dev/null)" in
    *"/usb"*) return 0 ;;
    *) return 1 ;;
  esac
}

URL=$(arg flash.url "")
SHA=$(arg flash.sha256 "")
SIZE=$(arg flash.size "")
DEV=$(arg flash.dev auto)
IP=$(arg flash.ip 192.168.50.60)
MASK=$(arg flash.mask 255.255.255.0)
DOREBOOT=$(arg flash.reboot 1)
FORCE=$(arg flash.force 0)

echo
echo "================================================================"
echo " DS410j USB stick flasher"
echo "================================================================"
say "kernel : $(uname -r)"
say "memory : $(awk '/MemAvailable/{print $2" kB available"}' /proc/meminfo)"
say "url    : ${URL:-<unset>}"
say "target : $DEV"
say "expect : ${SIZE:-<unset>} bytes, sha256 ${SHA:-<unset>}"
echo

[ -n "$URL" ] || die "no flash.url= on the kernel command line"

# --- network ---------------------------------------------------------------
say "bringing up eth0 as $IP"
ip link set eth0 up 2>/dev/null || ifconfig eth0 up || die "cannot bring up eth0"
ifconfig eth0 "$IP" netmask "$MASK" up || die "cannot address eth0"
# The link takes a moment to negotiate; without this the first wget can race it.
i=0
while [ $i -lt 30 ]; do
  [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ] && break
  sleep 1; i=$((i+1))
done
say "carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null) speed=$(cat /sys/class/net/eth0/speed 2>/dev/null)Mb/s"

# --- pick the target -------------------------------------------------------
# USB enumeration is slower than the rest of boot, so wait for something to show
# up before deciding there is nothing there.
say "waiting for a USB disk to enumerate"
i=0
while [ $i -lt 30 ]; do
  FOUND=""
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    is_usb "$n" && FOUND="$FOUND $n"
  done
  [ -n "$FOUND" ] && break
  sleep 1; i=$((i+1))
done

say "USB disks:${FOUND:- none}"
for d in /sys/block/sd*; do
  [ -e "$d" ] || continue
  n=$(basename "$d")
  say "  $n $(cat $d/size) sectors, usb=$(is_usb $n && echo yes || echo NO)" \
      "$(cat $d/device/model 2>/dev/null)"
done

if [ "$DEV" = auto ]; then
  set -- $FOUND
  [ $# -ge 1 ] || die "no USB disk found - is the stick plugged in?"
  [ $# -eq 1 ] || die "$# USB disks found ($FOUND) - say which with flash.dev=/dev/sdX"
  DEV=/dev/$1
  say "auto-selected $DEV"
fi

[ -b "$DEV" ] || die "$DEV is not a block device"
BASE=$(basename "$DEV")

# The check that stops this tool from eating a 3 TB array. The kernel should not
# even have sata_mv, but a flasher rebuilt without flasher.nix's --disable lines
# would, and then sda is whichever device won the probe race.
if is_usb "$BASE"; then
  say "$DEV is USB-attached, good"
elif [ "$FORCE" = 1 ]; then
  say "WARNING: $DEV is NOT USB-attached, proceeding only because flash.force=1"
else
  die "$DEV is not USB-attached - refusing. This is the check that keeps a
       SATA data drive from being overwritten. Use flash.dev=auto, or
       flash.force=1 if you are certain."
fi

# --- capacity --------------------------------------------------------------
# Without this a too-small stick fails at ENOSPC most of the way through, which
# looks like a mystery checksum mismatch several minutes later.
SECTORS=$(cat /sys/class/block/$BASE/size)
CAP=$((SECTORS * 512))
say "$DEV capacity $CAP bytes ($((CAP / 1000000)) MB, $SECTORS sectors)"
if [ -n "$SIZE" ]; then
  if [ "$CAP" -lt "$SIZE" ]; then
    die "$DEV holds $CAP bytes but the image needs $SIZE - too small, refusing"
  fi
  say "image needs $SIZE bytes, fits with $((CAP - SIZE)) to spare"
fi

# --- write -----------------------------------------------------------------
# Streamed: wget to stdout, dd to the device. Nothing is ever held in RAM beyond
# the pipe buffer, which is what makes a 700 MB image possible on a 118 MB box.
say "streaming image to $DEV - this takes a few minutes, do not interrupt"
T0=$(cut -d. -f1 /proc/uptime)
if ! wget -O - "$URL" | dd of="$DEV" bs=1M 2>&1; then
  die "the transfer did not complete; the stick is now inconsistent - re-run the flasher"
fi
T1=$(cut -d. -f1 /proc/uptime)
say "write finished in $((T1 - T0))s, flushing"
sync
say "flushed"

# --- verify ----------------------------------------------------------------
# Reading the stick back is the only thing that distinguishes "dd exited 0" from
# "the image is actually on the stick", and it is what makes an unattended
# reboot into the result defensible.
if [ -n "$SHA" ] && [ -n "$SIZE" ]; then
  say "verifying: reading back $SIZE bytes and hashing"
  GOT=$(dd if="$DEV" bs=1M 2>/dev/null | head -c "$SIZE" | sha256sum | cut -d' ' -f1)
  if [ "$GOT" = "$SHA" ]; then
    say "VERIFIED sha256 $GOT"
  else
    say "expected $SHA"
    say "got      $GOT"
    die "checksum mismatch - do NOT reboot into this image, re-run the flasher"
  fi
else
  say "no flash.sha256/flash.size given - skipping verification (not recommended)"
fi

# --- restart ---------------------------------------------------------------
# The board cannot reset itself; the MCU does it on a 'C' (PORTING.md 3.3).
# This image has no synology-mcu driver, so UART1 is still a plain tty and the
# byte can just be written to it.
if [ "$DOREBOOT" = 1 ]; then
  say "asking the MCU to restart the board"
  stty -F /dev/ttyS1 9600 cs8 -cstopb -parenb raw 2>/dev/null
  printf 'C' > /dev/ttyS1 2>/dev/null || say "could not write to /dev/ttyS1"
  sleep 5
  say "MCU did not restart the board; power-cycle it or use the front button"
fi

echo
say "done. Shell follows; the stick is flashed and verified."
exec /bin/sh
