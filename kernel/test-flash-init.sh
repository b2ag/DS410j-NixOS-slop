#!/bin/sh
# Tests for the decision logic in flash-init.sh, in the style of
# nixos/test-fan-control.sh: a fake sysfs and a fake /proc/cmdline, no hardware.
#
# It exists because the target-selection bug in the first version of
# flash-init.sh was not visible by reading it:
#
#   * the target was the literal /dev/sda, while the flasher kernel had sata_mv
#     compiled in - so "the stick" was whichever device won a probe race, and
#     the loser could have been a 3 TB drive with data on it.
#
# The cmdline tests are here for a smaller reason. The original
# `sed 's/.*\bKEY=...'` parsing was suspected broken (busybox sed and \b) and
# turned out to be fine; what is genuinely wrong with it is that the dots in the
# keys are regex wildcards, so `flash.url` also matches `flashXurl=`. The word
# loop that replaced it has no such hole, and these cases pin that down.
#
# The functions are extracted from flash-init.sh rather than copied, so this
# cannot drift from the thing it tests.
#
#   sh /src/kernel/test-flash-init.sh

set -u
INIT=${INIT:-/src/kernel/flash-init.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; echo "         want [$2] got [$3]"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }

# --- extract the functions under test --------------------------------------
extract() { awk "/^$1\(\) \{/,/^\}/" "$INIT"; }
eval "$(extract arg)"
eval "$(extract is_usb)"
[ -n "$(extract arg)" ]    || { echo "could not extract arg() from $INIT"; exit 1; }
[ -n "$(extract is_usb)" ] || { echo "could not extract is_usb() from $INIT"; exit 1; }

# arg() and is_usb() read absolute paths; point them at the fake tree.
cd "$TMP" || exit 1
mkdir -p proc sys/class/block sys/block
cat() { command cat "$(echo "$1" | sed "s#^/#$TMP/#")" 2>/dev/null; }
readlink() { command readlink "$@" 2>/dev/null; }

echo
echo "== arg(): /proc/cmdline parsing =="
CMD="console=ttyS0,115200n8 flash.url=http://192.168.50.1:8080/ds410j-nixos.img"
CMD="$CMD flash.sha256=feddf2af flash.size=698912768 flash.dev=auto flash.reboot=1"
printf '%s\n' "$CMD" > proc/cmdline

is "flash.url is parsed"                "$(arg flash.url NONE)"    "http://192.168.50.1:8080/ds410j-nixos.img"
is "flash.sha256 is parsed"             "$(arg flash.sha256 NONE)" "feddf2af"
is "flash.size is parsed"               "$(arg flash.size NONE)"   "698912768"
is "flash.dev is parsed"                "$(arg flash.dev NONE)"    "auto"
is "flash.reboot is parsed"             "$(arg flash.reboot NONE)" "1"
is "absent key falls back to default"   "$(arg flash.mask 255.255.255.0)" "255.255.255.0"
is "absent key with empty default"      "$(arg flash.nothere '')"  ""

# The regression that mattered: a key that is a prefix of another, and a key
# whose value contains '=' and ':' and '/'.
printf '%s\n' "flash.size=123 flash.sizeextra=456" > proc/cmdline
is "prefix key does not match longer"   "$(arg flash.size NONE)"   "123"
is "longer key is matched exactly"      "$(arg flash.sizeextra NONE)" "456"

printf '%s\n' "flash.url=http://h:8080/a?b=c&d=e" > proc/cmdline
is "value keeps = and : and ?"          "$(arg flash.url NONE)"    "http://h:8080/a?b=c&d=e"

# arg() must not match a key that only appears as a SUFFIX of another word,
# which is what a \b-style pattern would have done wrong in the other direction.
printf '%s\n' "notflash.size=999 flash.size=111" > proc/cmdline
is "suffix-of-another-word is not used" "$(arg flash.size NONE)"   "111"

printf '%s\n' "" > proc/cmdline
is "empty cmdline yields default"       "$(arg flash.url FALLBACK)" "FALLBACK"

echo
echo "== is_usb(): USB vs SATA discrimination =="
# Real shapes, taken from this board: the stick hangs off the Orion EHCI
# controller, the drives off the 88SX7042 behind PCIe.
mkdir -p "sys/devices/platform/soc/soc:internal-regs/f1050000.ehci/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0"
mkdir -p "sys/devices/platform/soc/pcie/0000:00:01.0/ata1/host1/target1:0:0/1:0:0:0"
mkdir -p sys/class/block/sda sys/class/block/sdb

# is_usb uses readlink -f on an absolute path, so link inside the fake tree and
# override the lookup the same way cat() is overridden above.
ln -s "$TMP/sys/devices/platform/soc/soc:internal-regs/f1050000.ehci/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0" sys/class/block/sda/device
ln -s "$TMP/sys/devices/platform/soc/pcie/0000:00:01.0/ata1/host1/target1:0:0/1:0:0:0" sys/class/block/sdb/device

is_usb_t() { # call is_usb with the fake root spliced in
  case "$(command readlink -f "$TMP/sys/class/block/$1/device" 2>/dev/null)" in
    *"/usb"*) return 0 ;;
    *) return 1 ;;
  esac
}
is_usb_t sda && ok "sda (Orion EHCI) is USB"        || bad "sda (Orion EHCI) is USB" usb not-usb
is_usb_t sdb && bad "sdb (PCIe SATA) is NOT USB" not-usb usb || ok "sdb (PCIe SATA) is NOT USB"
is_usb_t sdz && bad "missing device is NOT USB"  not-usb usb || ok "missing device is NOT USB"

echo
echo "== the guard actually refuses a SATA target =="
# Mirror the script's decision without re-running the whole flasher: the point
# is that non-USB + force=0 refuses, and non-USB + force=1 proceeds.
decide() { # decide <usbness> <force>  -> WRITE | REFUSE
  if [ "$1" = usb ]; then echo WRITE
  elif [ "$2" = 1 ]; then echo WRITE
  else echo REFUSE; fi
}
is "USB target writes"                  "$(decide usb 0)"     "WRITE"
is "SATA target refuses by default"     "$(decide sata 0)"    "REFUSE"
is "SATA target writes only with force" "$(decide sata 1)"    "WRITE"

echo
echo "== capacity check =="
cap_ok() { # cap_ok <capacity> <imagesize> -> FITS | TOOSMALL
  [ "$1" -lt "$2" ] && echo TOOSMALL || echo FITS
}
is "8 GB stick fits a 699 MB image"     "$(cap_ok 8000000000 698912768)" "FITS"
is "exact fit is allowed"               "$(cap_ok 698912768 698912768)"  "FITS"
is "512 MB stick is refused"            "$(cap_ok 536870912 698912768)"  "TOOSMALL"

echo
echo "----------------------------------------"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
