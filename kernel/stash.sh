#!/usr/bin/env bash
# Wait for the running kernel build, then persist artifacts + a binary cache
# into /src (host mount, survives VM resets).
set -u
NIXFLAGS="--extra-experimental-features nix-command"
CACHE=file:///src/nix-cache
OUT=/src/kernel/out

# 1. wait for nix-build to finish
while pgrep -f 'nix-build /src/kernel' >/dev/null 2>&1; do sleep 15; done

if ! grep -q 'uImage' /src/kernel/logs/build.log 2>/dev/null && [ ! -e /src/kernel/result ]; then
  echo "STATUS=BUILD_FAILED"
  tail -25 /src/kernel/logs/build.log
  exit 1
fi

# 2. copy the boot artifacts out of the store into /src
mkdir -p "$OUT"
cp -fL /src/kernel/result/zImage "$OUT"/ 2>/dev/null
cp -fL /src/kernel/result/zImage-dtb "$OUT"/ 2>/dev/null
cp -fL /src/kernel/result/uImage "$OUT"/ 2>/dev/null
cp -fL /src/kernel/result/kirkwood-ds409.dtb "$OUT"/ 2>/dev/null
cp -fL /src/kernel/result/config "$OUT"/kernel.config 2>/dev/null
cp -fL /src/kernel/result/sizes.txt "$OUT"/ 2>/dev/null
chmod u+w "$OUT"/* 2>/dev/null

# 3. binary cache: the expensive-to-rebuild pieces
echo "populating $CACHE ..."
KPATH=$(readlink -f /src/kernel/result)
CC=$(nix-build --no-out-link -E '(import <nixpkgs>{}).pkgsCross.armv5tel-multiplatform.stdenv.cc' 2>/dev/null)
BB=$(nix-build --no-out-link /src/kernel -A busyboxStatic 2>/dev/null)
SRCTAR=$(nix-build --no-out-link -E '(import <nixpkgs>{}).linuxKernel.packages.linux_6_12.kernel.src' 2>/dev/null)
nix $NIXFLAGS copy --to "$CACHE" $KPATH $CC $BB $SRCTAR "$NIX_PATH_SRC" 2>&1 | tail -5

echo "STATUS=OK"
echo "--- /src/kernel/out ---"
ls -la "$OUT"
echo "--- sizes ---"
cat "$OUT"/sizes.txt 2>/dev/null
echo "--- cache size ---"
du -sh /src/nix-cache 2>/dev/null
