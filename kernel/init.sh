#!/bin/sh
# Minimal initramfs init for DS410j mainline-kernel bring-up (PORTING.md M3).
/bin/busybox --install -s /bin

mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null

echo
echo "================================================================"
echo " DS410j mainline kernel bring-up  --  initramfs shell"
echo "================================================================"
echo "kernel : $(uname -a)"
echo "model  : $(cat /proc/device-tree/model 2>/dev/null)"
echo "memory : $(grep MemTotal /proc/meminfo)"
echo
echo "-- PCI devices --"
cat /proc/bus/pci/devices 2>/dev/null | awk '{print $1, $2}'
ls /sys/bus/pci/devices 2>/dev/null
echo
echo "-- block devices --"
cat /proc/partitions
echo
echo "-- network interfaces --"
ls /sys/class/net
echo
echo "-- mtd --"
cat /proc/mtd 2>/dev/null
echo
echo "Type 'exit' or Ctrl-D for a fresh shell. Nothing is written to disk."
echo

exec /bin/sh
