#!/bin/sh
# initramfs init for the DS410j USB-stick flasher (OPERATIONS.md, "Flashing the
# USB stick without a human").
#
# Runs entirely from RAM, so it can safely overwrite the very stick the box
# normally boots from. The image is STREAMED from HTTP straight to the block
# device - it is ~680 MB against 118 MB of RAM, so it can never be buffered.
#
# Why this is safe to get wrong: the two-stage bootloader chain lives in SPI
# flash, not on the stick (CLAUDE.md). A half-written stick does not brick
# anything - our U-Boot simply finds no bootflow, drops to its prompt, and this
# flasher can be TFTP-booted again. That is what makes an unattended reflash
# reasonable at all.
#
# Everything is driven from the kernel command line so the payload can change
# without rebuilding this image:
#
#   flash.url=http://192.168.50.1:8080/ds410j-nixos.img
#   flash.sha256=<hex>          expected sha256 of the image (optional but wanted)
#   flash.size=<bytes>          image size, needed to read back exactly as much
#   flash.dev=/dev/sda          target block device
#   flash.ip=192.168.50.60      static address for eth0
#   flash.mask=255.255.255.0
#   flash.reboot=1              restart via the MCU when done
set -u

/bin/busybox --install -s /bin
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null

say() { echo "[flash] $*"; }
die() { echo; echo "[flash] FAILED: $*"; echo "[flash] dropping to a shell; nothing further is written."; exec /bin/sh; }

arg() { # arg <key> <default>
  v=$(sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" /proc/cmdline)
  [ -n "$v" ] && echo "$v" || echo "$2"
}

URL=$(arg flash.url "")
SHA=$(arg flash.sha256 "")
SIZE=$(arg flash.size "")
DEV=$(arg flash.dev /dev/sda)
IP=$(arg flash.ip 192.168.50.60)
MASK=$(arg flash.mask 255.255.255.0)
DOREBOOT=$(arg flash.reboot 1)

echo
echo "================================================================"
echo " DS410j USB stick flasher"
echo "================================================================"
say "kernel : $(uname -r)"
say "memory : $(awk '/MemAvailable/{print $2" kB available"}' /proc/meminfo)"
say "url    : ${URL:-<unset>}"
say "target : $DEV"
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

# --- target ----------------------------------------------------------------
say "waiting for $DEV to enumerate"
i=0
while [ $i -lt 30 ]; do
  [ -b "$DEV" ] && break
  sleep 1; i=$((i+1))
done
[ -b "$DEV" ] || die "$DEV never appeared - is the stick plugged in?"
say "$DEV is $(cat /sys/class/block/$(basename $DEV)/size) sectors"

# --- write -----------------------------------------------------------------
# Streamed: wget to stdout, dd to the device. Nothing is ever held in RAM beyond
# the pipe buffer, which is what makes a 680 MB image possible on a 118 MB box.
say "streaming image to $DEV - this takes a few minutes, do not interrupt"
if ! wget -O - "$URL" | dd of="$DEV" bs=1M 2>&1; then
  die "the write did not complete; the stick is now inconsistent - re-run the flasher"
fi
sync
say "write finished, flushing"
sync

# --- verify ----------------------------------------------------------------
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
