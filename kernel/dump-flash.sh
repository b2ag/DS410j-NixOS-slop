#!/usr/bin/env bash
# Dump all six MTD partitions off the DS410j over the ethernet link and verify
# against device-side md5. Read-only on the device; PORTING.md section 7.1.
set -u
OUT=/src/flash-backup
mkdir -p "$OUT"
NAMES=(RedBoot zImage rd.gz vendor RedBoot-config FIS-directory)
SIZES=(524288 2097152 1310720 65536 131072 65536)
REF=(92a64d4550afa76bf1f44e1c9e2663ca
     a4fd1b47c07b2e18b114f0472523cd59
     75a04682bed20c6901eef1c85336059e
     cc15424e226bb735ab76d30383e4f214
     0dfbe8aa4c20b52e1b8bf3cb6cbdf193
     437b5ca21891d89728ef31703cc65c41)
PORT=9100
FAIL=0
for i in 0 1 2 3 4 5; do
  f="$OUT/mtd$i.bin"
  rm -f "$f"
  socat -u "TCP-LISTEN:$PORT,reuseaddr,bind=192.168.50.1" "OPEN:$f,creat,trunc" &
  LPID=$!
  sleep 1
  /src/kernel/sercmd.sh "nc 192.168.50.1 $PORT < /dev/mtd$i" 30 >/dev/null
  wait $LPID 2>/dev/null
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  md=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$sz" = "${SIZES[$i]}" ] && [ "$md" = "${REF[$i]}" ]; then
    printf 'mtd%s %-16s %8s bytes  md5 %s  OK\n' "$i" "${NAMES[$i]}" "$sz" "$md"
  else
    printf 'mtd%s %-16s %8s bytes (want %s)  md5 %s (want %s)  MISMATCH\n' \
      "$i" "${NAMES[$i]}" "$sz" "${SIZES[$i]}" "$md" "${REF[$i]}"
    FAIL=1
  fi
  PORT=$((PORT+1))
done
exit $FAIL
