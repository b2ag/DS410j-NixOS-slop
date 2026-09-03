# Operating this rig

How to actually drive the DS410j from this container. `PORTING.md` is the plan and the
source of truth for findings; this file is the bench setup and the hard-won gotchas.
Read both before touching flash.

## Topology

| Thing | Value |
|---|---|
| Serial console | **`/dev/ttyUSB0`**, 115200 8N1, raw, no flow control (was `/dev/ttyS1` until the adapter moved to USB passthrough) |
| Container NIC to the DS410j | `eth1` = **192.168.50.1/24** (ASIX AX88772B, USB passthrough) |
| DS410j address (set by hand each boot) | **192.168.50.50** |
| TFTP server | dnsmasq, `enable-tftp`, root **`/var/lib/tftpboot`** (writable) |
| DHCP pool (unused; we use static) | 192.168.50.100-200 |

The DS410j bootloader env is **RAM-only** (no `saveenv`), so `ipaddr`/`serverip`/
`netmask` must be re-set after **every** power cycle.

## Helper scripts (`/src/kernel/`)

| Script | Purpose |
|---|---|
| `serlog.sh` | The serial logger. `exec cat $SERIAL_DEV >> logs/serial.log`. Start with `setsid`. |
| `sercmd.sh "<cmd>" [secs]` | Send a command, print only the newly captured output. |
| `spam.sh [secs]` | Spam spaces at the console to interrupt autoboot (`bootdelay=3`). |
| `dump-flash.sh` | Dump all six MTD partitions over ethernet and verify against device md5. |
| `init.sh` | The initramfs init baked into the bring-up kernel. |

Typical session start:

```sh
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts -ixon -ixoff raw -echo
setsid /src/kernel/serlog.sh & disown
```

## Gotchas that cost real time today

1. **Exactly one reader on the console.** Two `cat` processes silently steal each
   other's bytes and you get plausible-looking garbled output
   (`U-Bo1.4 ( 2010 27:44ell ven: 3arvell>>`). Check with:
   `ps -eo args | grep -cE '^cat /dev/ttyUSB0'` - must be exactly 1.

   **The device name is not stable across host<->VM handover changes.** It was
   `/dev/ttyS1` and became `/dev/ttyUSB0` when the adapter moved to USB
   passthrough, same as the ethernet adapter. All three helper scripts take
   `SERIAL_DEV` (default `/dev/ttyUSB0`) so this is one variable, not three edits.
   A silent console after any host-side change is this, not a dead board -
   check `cat /sys/class/net/eth1/carrier` before suspecting the hardware.

2. **`pgrep -f` / `pkill -f` match your own command line.** This bit four times: it
   killed the shell issuing the `pkill` (exit 144), and it made two waiter loops spin
   forever because `while pgrep -f 'nix-build ... kernelMin'` matched the waiter itself.
   Use the bracket trick: `pgrep -f 'serlo[g].sh'`, or kill by PID.

   **The bracket trick is not enough** if the same command line also *starts* the
   thing: `setsid ./spam.sh 45 & ... ; pkill -f 'spa[m].sh'` still matches, because
   the literal `./spam.sh 45` earlier in the line satisfies the regex. That is a
   fifth occurrence, same exit 144. **Kill by PID.**

3. **Arm `spam.sh` BEFORE anything that can reset the board**, not after. `bootdelay`
   is 3 s. Starting the spammer after `sercmd.sh` returns is already too late, and the
   board autoboots into stock DSM.

4. **Warm reboot does not work** (PORTING.md §3.3). Neither Linux nor U-Boot 2026.07 can
   reset this SoC; both hang. **Every reset needs a human to power cycle.** Budget for
   it - you cannot iterate unattended.

5. **`mkimage` fails on `/src`**: `Can't map ... Invalid argument`. `/src` is a 9p mount
   and `mkimage` needs `mmap`. Build images in `/tmp` and copy them over.

6. **Give nix builds a roomy `TMPDIR`** (`TMPDIR=/tmp/nixbuild`). The session tmp
   filesystem is small; filling it breaks the harness's own output capture.

7. **Load kernels high.** `bootm` memmoves to the uImage load address, and the stock
   U-Boot lives at `0x00600000` with the low 8 MB reserved. Anything over ~5.9 MB loaded
   at `0x00008000` overwrites the running loader mid-copy and wedges the CPU silently.
   Build uImages with `-a 0x02000000 -e 0x02000000` and the position-independent zImage
   relocates itself. See PORTING.md §4.

8. **`carrier` tells you whether the DS410j is powered**, which serial cannot: a box
   that is off and a box whose console is wedged both look like silence. Check
   `cat /sys/class/net/eth1/carrier` - `0` means unpowered, `1` means alive. Note the
   DS410j needs **both** outlet power *and* a front-panel button press.

9. **The SPI flash is write-protected in hardware** (PORTING.md §2). `sf erase`
   returns `ERROR: flash area is locked` until `sf protect unlock` runs, and because
   the M25P32's block-protect bits are top-anchored, unlocking far enough to reach the
   `zImage` slot unprotects **mtd0 as well**. Re-lock (`sf protect lock 0 0x400000`)
   as soon as the write is verified. The stock loader has always advertised this:
   `flinfo` -> `Write Protection: All`.

## Known-good sequences

Stock loader -> TFTP -> Linux (bring-up kernel with busybox initramfs):

```
setenv ipaddr 192.168.50.50; setenv serverip 192.168.50.1; setenv netmask 255.255.255.0
tftpboot 0x04000000 uImage-hi
bootm 0x04000000
```

Stock loader -> modern U-Boot -> TFTP -> Linux (the full chain, PORTING.md §5.1):

```
setenv ipaddr 192.168.50.50; setenv serverip 192.168.50.1; setenv netmask 255.255.255.0
tftpboot 0x02000000 u-boot-ds109.bin
go 0x02000000
        # now in U-Boot 2026.07, prompt "=>"
setenv ipaddr 192.168.50.50; setenv serverip 192.168.50.1; setenv netmask 255.255.255.0
setenv bootargs console=ttyS0,115200
tftpboot 0x00800000 uImage-hi
bootm 0x00800000
```

Rehearsal for the unattended-boot hook - stock loader -> `bootm` -> modern U-Boot
(PORTING.md §4). Note the **real flash address** as the second argument: that makes
this bit-identical to the flashed path except for where argument 1 points.

```
setenv ipaddr 192.168.50.50; setenv serverip 192.168.50.1; setenv netmask 255.255.255.0
tftpboot 0x04000000 uImage-ub-kernel
bootm 0x04000000 0xF8280000
```

Expect `## Booting image at 04000000`, `Load Address: 02000000`, `Verifying Checksum
... OK`, then `## Loading Ramdisk Image at f8280000` naming
`synology_88f6281_410j 5967` with its own `Verifying Checksum ... OK`, then the
U-Boot 2026.07 banner. `uImage-ub-kernel-oldcfg` is the same wrapper around the
pre-10.9 binary, to bisect if the `SKIP_LOWLEVEL_INIT_ONLY` change is implicated.

Verify flash is untouched (from the stock loader):

```
crc32 0xf8000000 0x400000     ->  4b513de1 as of §2 (8bc4bbb7 = pristine stock)
```

or from the chainloaded U-Boot 2026.07, which reads the chip over SPI rather than
through the mapped window:

```
sf probe
sf read 0x03800000 0 0x400000
crc32 0x03800000 0x400000
```

or from Linux: `for i in 0 1 2 3 4 5; do md5sum /dev/mtd$i; done` and compare against
`flash-backup/CHECKSUMS.txt` - **mtd1, mtd2 and mtd4 are all expected to differ now**
(our U-Boot, the ramdisk stub, our environment). mtd0, mtd3 and mtd5 must still match.

## Builds

```sh
TMPDIR=/tmp/nixbuild nix-build /src/kernel -A kernel     -o /src/kernel/result      # bring-up, 7.2 MB
TMPDIR=/tmp/nixbuild nix-build /src/kernel -A kernelMin  -o /src/kernel/result-min  # flash candidate, 2.91 MiB
TMPDIR=/tmp/nixbuild nix-build /src/uboot                -o /src/uboot/result       # U-Boot 2026.07, 386 KB
TMPDIR=/tmp/nixbuild nix-build /src/nixos -A image       -o /src/nixos/result       # NixOS USB image, ~655 MiB
```

## Writing the NixOS image to a USB stick

`nix-build /src/nixos -A image` leaves the image under `result/sd-image/`. It is
uncompressed, so it is `dd`-able as-is:

A copy is kept outside the store at **`/src/nixos/out/ds410j-nixos.img`**, refreshed
after every build, because the store path is awkward to reach from the host.

```sh
IMG=/src/nixos/out/ds410j-nixos.img
sha256sum "$IMG"          # ce08268dba8dd4e74eb91d078f616807ebaa58bc1733dc16faec0042b98ddc18
sudo dd if="$IMG" of=/dev/sdX bs=4M status=progress conv=fsync
```

**Check `/dev/sdX` twice** - `lsblk` before and after plugging the stick in. 784 MiB
of the 8 GB stick is used; the root partition grows to fill the rest on first boot
(`sdImage.expandOnBoot`).

Nothing on the DS410j needs changing to boot it: the flashed `bootcmd` is already
`usb start; bootflow scan`, and U-Boot's bootstd searches `/extlinux/extlinux.conf`
and `/boot/extlinux/extlinux.conf` on every partition (PORTING.md §2). Serial
console is `console=ttyS0,115200n8`; root password is `ds410j` for v1.

Reading the image back without mounting it (no loop devices in the container):

```sh
dd if="$IMG" of=/tmp/p2.img bs=1M skip=38 count=746 status=none   # part 2 starts at 38 MiB
debugfs -R "cat /boot/extlinux/extlinux.conf" /tmp/p2.img
```

Only the kernel/U-Boot derivations build locally; the armv5tel cross toolchain
substitutes from `cache.nixos.org`.

---

# FLASH STATE - read before any further flash write

**The first write has happened (2026-09-03, PORTING.md §2).** mtd1 no longer holds
Synology's kernel; it holds our `IH_TYPE_KERNEL`-wrapped U-Boot 2026.07, verified
byte-for-byte. mtd0 and mtd2 are untouched and write protection has been restored.

- Whole-chip `crc32 0xf8000000 0x400000` is now **`4b513de1`**. Per-partition:
  mtd0 `273ca0c6`, mtd1 `5b703dd6`, mtd2 `5fd81497`, mtd3 `cab00674`, mtd4 `06ed043d`,
  mtd5 `368b19d9`. (`8bc4bbb7` = pristine stock.) mtd1 holds our U-Boot, mtd2 a
  685-byte ramdisk stub rather than Synology's `rd.gz`, and mtd4 a real U-Boot
  environment.
- `flash-backup/` and `flash-backup-copy2/` still describe the **stock** chip and both
  still verify clean. They remain the recovery source.
- Stock DSM no longer boots. **Intended** - DSM is expendable; what must survive is the
  two-stage chain (mtd0 stock loader -> mtd1 our U-Boot). See CLAUDE.md, "What we are
  protecting". `flash-backup/mtd1.bin` can restore it if ever wanted.

The checklist below still governs every future write.

## Before writing anything

- [ ] Re-verify the backup is still good: `md5sum -c` against
      `flash-backup/CHECKSUMS.txt`, and confirm `flash-backup-copy2/` matches.
- [ ] Confirm the on-device flash is where you think it is: `crc32 0xf8000000 0x400000`
      = `4b513de1` as of §2.
- [ ] Confirm the serial console is attached and working. A bricked loader with no UART
      is a paperweight.
- [ ] **Rehearse the exact payload in RAM first.** TFTP the identical bytes to the
      address `bootm` will use and confirm they run. Only flash bytes you have already
      watched boot.
- [ ] **Predict the post-write checksums offline, before writing.** Compute what each
      touched and untouched region *should* be from the backups, then verify by reading
      back over `sf`. A matching whole-chip crc32 is what proves nothing else moved.
- [ ] `sf protect unlock 0 0x400000` first, and **re-lock as soon as it verifies**
      (gotcha 8) - unlocking necessarily exposes mtd0 too.

## Open questions to settle BEFORE flashing

1. ~~**`CONFIG_TEXT_BASE` for the flashed image.**~~ **Settled** (PORTING.md §4).
   TEXT_BASE stays `0x02000000` - the address 10.7 already proved - and the image is
   wrapped as `IH_TYPE_KERNEL` with `-a 0x02000000 -e 0x02000000`, so `bootm` memmoves
   the payload exactly there. `0x02000000` is clear of the running stock loader
   (`0x00600000`-`0x0068B3B4`) and of the reserved low 8 MB.
   **Do not use `IH_TYPE_STANDALONE`**: for that type U-Boot 1.1.4 overwrites `ih_load`
   with the second `bootm` argument, so the payload would be memmoved into the SPI NOR
   window at `0xF8280000` and entered at an address never written.
2. ~~**Cache state differs between `go` and `bootm`.**~~ **Settled, both ends.** The
   `IH_TYPE_KERNEL` path runs `cleanup_before_linux()` (disable interrupts, disable
   I-cache, D-cache and L2, invalidate) before entering the payload, and the payload
   now runs `cpu_init_crit` itself via `CONFIG_SKIP_LOWLEVEL_INIT_ONLY`
   (PORTING.md §5.1). Still **rehearse with `bootm`, not `go`.**
3. ~~**Writing mtd1 destroys the ability to boot stock DSM.**~~ **Done, and not a
   concern** - DSM is expendable by project decision (CLAUDE.md, "What we are
   protecting"). The thing to protect is the two-stage chain, not the stock OS.
4. **NEW: mtd2 is now load-bearing for *our* boot chain too.** The `IH_TYPE_KERNEL`
   hook makes the stock `bootcmd`'s second argument a real ramdisk argument, and
   Synology's `rd.gz` at `0xF8280000` is what satisfies it (valid `LINUX/ARM/RAMDISK/gzip`
   uImage, both CRCs OK). If mtd2 is ever erased or corrupted, `bootm` `do_reset()`s and
   the box boot-loops. **Leave mtd2 alone**, or replace it with an equally valid ramdisk
   uImage in the same write.

## Risk ranking of the candidate writes

| Target | Risk | Recovery if it goes wrong |
|---|---|---|
| **mtd4** (env, 0x3D0000) | **lowest** - all zeros today, and the stock loader provably never reads it (PORTING.md §5.4: built with `CFG_ENV_IS_NOWHERE`) | Re-flash 128 KB from backup; stock loader unaffected either way |
| **mtd1** (our U-Boot, 0x80000) | **low** - stock loader at offset 0 is untouched and still TFTP-boots | Re-flash over TFTP+Linux via the stock loader; the chain's stage 1 is what makes this safe |
| **mtd2** (ramdisk arg, 0x280000) | **medium** - a *blank* mtd2 boot-loops instead of dropping to a prompt | Interrupt autoboot with `spam.sh` (bootdelay=3 still applies each loop), then TFTP |
| **mtd0** (bootloader, 0x0) | **HIGH - do not** | External SPI programmer only (desolder). Full-chip image is `ds410j-flash-full-4MB.bin` |

Prefer mtd4, then mtd1. `PORTING.md` §4 has the reasoning; mtd0 is a last
resort and the plan should not require it.
