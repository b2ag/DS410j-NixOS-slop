# NixOS on Synology DS410j — Porting Brief

Mainline Linux + NixOS on a Synology DS410j: Marvell Kirkwood 88F6281, armv5tel,
128 MB RAM, 4 MB SPI NOR, Marvell U-Boot 1.1.4.

**Status: working.** The box cold-boots unattended to NixOS 26.11 on kernel
6.12.104, with a serial login and ssh, and nothing attached but a USB stick.
`systemctl is-system-running` reports `running`, zero failed units.

```
stock Marvell U-Boot 1.1.4 (mtd0, never written)
  -> our U-Boot 2026.07 (mtd1)      bootm F8080000 F8280000
    -> USB stick, extlinux          bootcmd = "usb start; bootflow scan"
      -> NixOS 26.11 / Linux 6.12.104
```

`OPERATIONS.md` is the bench setup: serial, TFTP, helper scripts, and the flash
checklist. Build commands live in `kernel/`, `uboot/` and `nixos/` — read the
`.nix` files, they carry their own reasoning.

### Confidence markers

- **[CONFIRMED]** — observed on this hardware.
- **[LIKELY]** — strong inference, not verified.
- **[VERIFY]** — must be checked before being relied on.

Preserve this convention. Never silently promote a `[VERIFY]`; promote it only
after checking, and say what you checked against.

---

## 0. Rules that must not be broken

- **Never write `mtd0`.** Flash offset 0, the stock loader, the only recovery path
  short of a SOIC clip. In practice: **never run `bubt`**. This outranks
  everything else here.
- **Keep the chain two-stage.** Do not "simplify" by putting our U-Boot in mtd0.
  Stage 1 is irreplaceable and TFTP-boots; stage 2 is re-flashable *through* it.
  That redundancy is the entire brick-resistance story.
- **Serial console working before any flash write.** A bricked loader with no UART
  is a paperweight.
- **Never run `nix` evaluation on the device.** 118 MB will OOM the evaluator.
  Everything cross-compiles on x86_64. Copying a closure to the device is fine.
- **mtd2 must never be blank.** The stock `bootcmd`'s second argument is a real
  ramdisk argument (§4); a blank mtd2 makes the loader `do_reset()` in a loop.
  It may be *replaced*, but only by an equally valid ramdisk uImage.
- **Do not run a U-Boot without the fan patch with drives fitted** (§5.3).
- Stock DSM is expendable and no longer boots. That is intended. The recovery
  requirement is that mtd0 still TFTP-boots, not that DSM works.

---

## 1. Hardware baseline

All [CONFIRMED] on this board.

| Item | Value |
|---|---|
| SoC | Marvell Kirkwood 88F6281, Feroceon 88FR131 rev 1, ARMv5TE, ~800 MHz |
| RAM | 128 MB total, 118 MB usable, soldered |
| Flash | 4 MB SPI NOR, ST M25P32, 64 x 64 KB, read-mapped at `0xf8000000` |
| SATA | **PCIe** Marvell 88SX7042 (`11ab:7042`), Gen-IIE, 4 ports. Not the SoC's native ports |
| Bays | bay -> port is 1:1 across all four (bay1=`ata1` .. bay4=`ata4`); no port multiplier |
| Ethernet | integrated Kirkwood GbE, `mv643xx_eth`, wired port is **eth0**, links at 100 Mb/s |
| PHY | `ethphy1` (MDIO addr 9) is **absent** — enabling `&eth1` is wrong for this board |
| USB | 2 x USB 2.0 `ehci-orion`, behind an internal Genesys GL850G 4-port hub (`05e3:0608`) |
| RTC | Ricoh `rs5c372a`, keeps time across power cycles |
| Crypto | CESA present |
| hwmon | **none at all** — there is no temperature sensor on this board |
| Fan | 3-bit GPIO speed select on GPIO0 **15/16/17**, `0` = off; alarm on 18 |
| MAC | `00:11:32:02:f9:a6` (from mtd3, the vendor partition) |

The SATA controller being behind PCIe is the most commonly-forgotten fact here:
anything that drops `CONFIG_PCI` or Kirkwood PCIe host support loses all four bays.

---

## 2. Flash map and recovery

Six partitions, stock Synology labels. The `fis`-named ones are inherited labels
with nothing behind them — there is no RedBoot and no FIS directory.

| Part | Offset | Size | Label | Contents now |
|---|---|---|---|---|
| mtd0 | `0x000000` | 512 K | RedBoot | **stock Marvell U-Boot 1.1.4 — never written** |
| mtd1 | `0x080000` | 2 M | zImage | our U-Boot 2026.07, `IH_TYPE_KERNEL`-wrapped |
| mtd2 | `0x280000` | 1.25 M | rd.gz | 685-byte ramdisk stub (§4) |
| mtd3 | `0x3C0000` | 64 K | vendor | MAC, serial — untouched |
| mtd4 | `0x3D0000` | 128 K | RedBoot config | our U-Boot environment |
| mtd5 | `0x3F0000` | 64 K | FIS directory | untouched |

Checksums (`crc32`, current):

```
whole chip 4b513de1     (8bc4bbb7 = pristine stock)
mtd0 273ca0c6   mtd1 5b703dd6   mtd2 5fd81497
mtd3 cab00674   mtd4 06ed043d   mtd5 368b19d9
```

**Backups.** `flash-backup/` holds all six stock partitions plus a full-chip image,
checksummed, and is committed. `flash-backup-copy2/` is a byte-identical off-git
copy — the M1 safety net wants two copies. Reproduce with `kernel/dump-flash.sh`.

**The flash is hardware write-protected.** `sf erase` fails with `ERROR: flash area
is locked` until `sf protect unlock` runs. The M25P32's block-protect bits are
**top-anchored**, so unlocking far enough to reach mtd1 unprotects mtd0 too —
always re-lock immediately after verifying a write, and batch writes into as few
unlock windows as possible.

**Recovery.** A corrupt mtd1 does *not* boot-loop: `do_bootm()` returns to the
shell on the main image's bad magic / header / data CRC, so you land at the stock
`Marvell>>` prompt and can TFTP a replacement. Only *ramdisk* failures call
`do_reset()`. A blank mtd2 is therefore the more dangerous mistake of the two.

Reclaimable space, if ever needed: ~1.6 MB in mtd1 after our U-Boot, ~1.25 MB in
mtd2 behind the stub, 64 K in mtd5. Non-contiguous.

---

## 3. Constraints that shape everything

### 3.1 118 MB of RAM

Drives every size decision. Measured on the running system: 86.5 MB available to
the kernel after reservations, 95 MB total to userspace, **54 MB free** with the
firewall up and zram providing 47 MB of swap.

Consequences: no nix on the device, cross-compilation only, a deliberately small
closure, and no systemd-in-initrd (§6.2).

### 3.2 ARMv5TE has no 64-bit atomics

ARMv5TE predates ARMv6's `LDREX`/`STREX`; all it has is `SWP`, a 32-bit swap.
64-bit atomics therefore cannot be lock-free. This is the single most disruptive
property of the architecture and it is **not** language-specific.

- It is why **`CONFIG_KUSER_HELPERS=y` is mandatory** — userspace atomics go
  through the kernel helper page. Without it every glibc binary misbehaves.
- **C/C++ degrades quietly**: GCC emits out-of-line `libatomic` calls backed by a
  lock table. Correct, just not lock-free — you only have to link `-latomic`.
- **Rust refuses.** `rustc --print cfg --target armv5te-unknown-linux-gnueabi`
  lists `target_has_atomic` of 8/16/32/ptr and **no 64**, so `AtomicU64` does not
  exist as a type. Any crate naming one fails to compile. Rust will not silently
  substitute a lock, because that would break the signal-safety the type implies.

Both halves have bitten. Rust: NixOS's `switch-to-configuration-ng` and, sideways,
`bcachefs-tools` via `nixos-generate-config` (§6.1). C++: protobuf, whose CMake
probes correctly and then dies in the *remediation* path — a hardcoded
`target_link_libraries(libprotobuf ...)` inside a function that takes the target as
a parameter, dead code on every mainstream arch. It reached the closure through
`pkgs.host` -> `bind` -> `--enable-dnstap` -> `protobufc`; an overlay dropping
dnstap removes it (`uboot`-style patches live in `nixos/configuration.nix`).

Expect more of these. The pattern is not "this cannot work" but "this path is so
rarely taken that it is broken".

### 3.3 No hwmon, no working SoC reset

There is no temperature sensor anywhere on this board, so fan control has no
kernel-side input and needs a userspace daemon polling drive SMART temps (§7.1).

**Warm reboot does not work.** `systemctl reboot` completes the entire shutdown —
unmounts, swaps off, SCSI caches flushed — and then hangs at
`reboot: Restarting system`. Neither Linux nor U-Boot 2026.07 can reset this SoC;
the *stock* loader can, so the hardware path exists and mainline does not reach it.
Practical consequence: power-cycling after `Restarting system` is **safe**, but
every reset needs a human. **`poweroff` does work** [CONFIRMED] — the asymmetry is
that the QNAP power-reset path cuts power but cannot restart.

### 3.4 No binary cache for target packages

`cache.nixos.org` serves the x86_64 *cross toolchain* (and even a prebuilt
armv5tel cross-rustc), but not armv5tel target packages. Everything in the closure
is a from-source cross build, so anything added to the system is paid for in build
time. That is the main reason the configuration is as aggressively trimmed as it is.

---

## 4. The boot chain

Four stages. The stock loader's `bootcmd` is `bootm F8080000 F8280000` and
**cannot be changed** — U-Boot 1.1.4 has no `saveenv`, so all `setenv` is RAM-only.
That fixed command is what everything else is built around.

**The payload in mtd1 must be `IH_TYPE_KERNEL`, not `IH_TYPE_STANDALONE`.** For
standalone images `do_bootm()` overwrites `ih_load` with the second argument:

```c
case IH_TYPE_STANDALONE:
    /* A second argument overwrites the load address */
    if (argc > 2)
        hdr->ih_load = htonl(simple_strtoul(argv[2], NULL, 16));
```

so the payload would be memmoved into the SPI NOR window at `0xF8280000` and
entered at an address never written. `IH_TYPE_KERNEL` leaves `ih_load` alone.

Its cost is that the second argument becomes a **real ramdisk argument**: something
at `0xF8280000` must parse as a valid `LINUX/ARM/RAMDISK` uImage with good header
and data CRCs, or the loader `do_reset()`s in a loop. `uboot/out/stub-ramdisk.uimg`
is a 685-byte image that satisfies it. ARM's `do_bootm_linux` never *copies* the
ramdisk (that memmove is guarded by `CONFIG_B2`/`EVB4510`/`ARMADILLO`), it only
validates it and records an ATAG — so no DRAM outside the load address is touched.

Stage 2 is entered at `0x02000000`, clear of the stock loader (`0x00600000`) and
its reserved low 8 MB.

U-Boot's bootstd tries `/extlinux/extlinux.conf` then `/boot/extlinux/extlinux.conf`
on every partition (`boot/bootstd-uclass.c`, `default_prefixes[]`), and
`CONFIG_BOOTSTD_FULL` is off so the DT override is never read. `/boot` therefore
lives *inside* the ext4 root partition and no separate boot partition is needed.

---

## 5. U-Boot: the DS410j patches

`ds109_defconfig` is the closest in-tree target but does not work as shipped. All
patches live in `uboot/default.nix` with the reasoning inline. Build with
`CONFIG_DEBUG_UART` always — it prints from the first instructions and is the
difference between a diagnosable hang and silence.

### 5.1 Chainload prerequisites

- `CONFIG_TEXT_BASE=0x02000000` — must not be `0x600000`, which is where the
  running stock loader lives.
- `CONFIG_CUSTOM_SYS_INIT_SP_ADDR=0x01f00000` — the default `0xc8012000` is
  Kirkwood internal SRAM, whose window is not mapped when chainloaded. U-Boot
  faults on its first stack push, before any console exists: total silence.
- `CONFIG_SKIP_LOWLEVEL_INIT_ONLY`, **not** `SKIP_LOWLEVEL_INIT`. The latter skips
  all of `cpu_init_crit`, inheriting the stock loader's cache and MMU state. The
  former still flushes/invalidates and disables the MMU, skipping only the DDR/pll
  re-init that must not run twice.
- `ethaddr` baked into the built-in environment. The eth uclass fails the device at
  first probe without a MAC, and every retry then trips `mdio_register`'s duplicate
  name check. Setting it from the shell is too late.

### 5.2 USB: two bugs, neither of them a timeout

Every stick is behind the internal GL850G hub. Linux enumerates instantly; U-Boot
saw nothing.

**Bug 1 — no settle before port reset.** `usb_hub_port_connect_change()` goes
straight from noticing a connect to `usb_hub_port_reset()`, but USB 2.0 §7.1.7.3
(TATTDB) requires ≥100 ms first. Without it the reset lands before the high-speed
chirp settles and the next control transfer fails with `unable to get device
descriptor (error=-1)`. Fixed with `mdelay(200)`.

**Bug 2 — a latched change is treated as a device.** `usb_scan_port()` keeps
waiting only when *neither* bit is set:

```c
if (!(portchange & USB_PORT_STAT_C_CONNECTION) &&
    !(portstatus & USB_PORT_STAT_CONNECTION)) { /* keep waiting */ }
```

A VBUS ramp produces a latched `C_CONNECTION` with `CONNECTION` still clear
(`Port 1 Status 100 Change 1`; a healthy port reads `0x101`). That falls through,
is acted on as a device, rejected as a disconnect, and **the port is removed from
the scan list permanently**. Fixed by requiring the `CONNECTION` bit, which keeps
upstream's documented `CCS set but CSC not` case working.

Three dead ends, recorded so nobody repeats them:

- Raising `CONFIG_USB_HUB_DEBOUNCE_TIMEOUT` does nothing — the port is dropped
  before any debouncing can happen.
- **A DEBUG build "works" throughout.** Its `debug()` printfs at 115200 baud supply
  the missing delays. Never conclude a timing fix works from a DEBUG build.
- **`go`-chainloading a new U-Boot from a running one inherits already-powered hub
  ports**, so it never exercises the VBUS ramp and always succeeds. A USB fix
  validated that way is not validated. Only a real power cycle tests it.

### 5.3 The fan — safety, not polish

Our U-Boot switched the fans **off**, and Linux never turned them back on.

The ds109 MPP table reconfigures MPP15/16/17 as GPIO — the DS109's own fan is on
32-35, a different DTS node — and leaves them low, which is speed `0` = off.
`kirkwood-ds409.dts` sets `gpio-fan-150-15-18` to `status = "okay"`, but the driver
fails to probe (`setup of GPIO alarm failed: -524`), so the pins keep whatever
U-Boot left. This was invisible during early bring-up because that kernel was
booted straight from the *stock* loader, which leaves the fans running.

`board_init()` now pins a safe speed (3 = 3300 rpm; `DS410J_FAN_SPEED`). Data is
written before the output enable so the pins never glitch through 0. The encoding
is not monotonic — 4 is 3000 rpm, *below* 3's 3300.

The `kw_gpio_*` helpers are declared in `mach/gpio.h` but **have no implementation
anywhere in U-Boot 2026.07**, so the registers are driven directly. On Kirkwood a
**0** bit in `GPIO_IO_CONF` *enables* the output.

### 5.4 extlinux support

`ds109_defconfig` predates distro boot. `kernel_addr_r`, `fdt_addr_r`,
`ramdisk_addr_r`, `scriptaddr`, `pxefile_addr_r` and `bootm_size` are baked into
the built-in environment, and `CONFIG_SUPPORT_RAW_INITRD=y` is required — NixOS's
initrd is a raw gzipped cpio, not a uImage, and without it the kernel loads and
then dies with `Wrong Ramdisk Image Format`.

**A saved environment in mtd4 with a valid CRC replaces the built-in defaults
wholesale.** Baking values into the image is not enough on a box whose mtd4 is
already written; both have to be updated together.

Writing mtd4 is safe from the stock loader's point of view: **it has no stored
environment at all** [CONFIRMED]. Its banner prints `Using default environment`,
which in `common/env_common.c` is the `CFG_ENV_IS_NOWHERE` branch — the
`*** Warning - bad CRC` string does not exist in `mtd0.bin`, nor do `saveenv`,
`Erasing Flash` or `Writing to Flash`. So an environment at `0x3D0000` is invisible
to stage 1 and cannot disturb its `bootcmd`. That is also *why* there is no
`saveenv`, rather than it being a separate quirk.

---

## 6. NixOS configuration: the non-obvious choices

`nixos/` cross-compiles the whole image on x86_64.
`nixpkgs.hostPlatform = { config = "armv5tel-unknown-linux-gnueabi"; }` — byte-identical
to `pkgsCross.armv5tel-multiplatform`, so the cached cross toolchain still
substitutes. The image reuses nixpkgs' own `sd-image.nix`, which needs no VM.

### 6.1 Keeping Rust out

**`system.switch.enableNg` no longer exists** in nixpkgs 26.11 — the option
hard-errors, because the Rust `switch-to-configuration-ng` is the only
implementation left. The replacement is **`system.switch.enable = false`**, which
fits better anyway: its own documentation calls it "good for image based appliances
where updates are handled outside the image".

Rust also enters sideways: `nixos-generate-config` references `bcachefs-tools`, so
the `system.tools.nixos-*` scripts are all disabled. They cannot work on a machine
that cannot evaluate nix regardless.

### 6.2 Fitting 118 MB

Three independent fixes, each worth real memory:

| | before | after |
|---|---|---|
| initrd, unpacked | 56.7 MB | 20.4 MB |
| `cma-reserved` | 16 MB | 0 |
| modules built | 6,083 / 106 MB | 445 / 7.9 MB |

- **`boot.initrd.systemd.enable = false`.** The systemd initrd was 17 MB of
  systemd plus 6.5 MB of openssl, tpm2-tss and libxml2. It could not unpack in the
  RAM available: `Out of memory and no killable processes`.
  **Caveat: the scripted initrd is deprecated and slated for removal in 26.11.**
  The durable answer is `boot.initrd.enable = false` — root on plain ext4 with the
  drivers built in, which we are most of the way toward already (§7.3).
- **`cma=0` on the kernel command line.** `CMA = no` does *not* work: nixpkgs'
  ARM32 config sets `CMA_DEBUGFS`/`CMA_SYSFS = yes`, which depend on CMA, so
  kconfig keeps it enabled whatever you ask for. Zeroing the *size* works, and
  `kernel/dma/contiguous.c` prefers the command line.
- **`autoModules = false`.** nixpkgs answers `m` to every kconfig question it has
  no answer for (`generate-config.pl`), which is why a headless ARMv5 NAS was
  compiling DRM drivers and IIO pressure sensors. `nixos/gen-driver-modules.py`
  is the middle ground: kconfig symbols are not path-qualified but the Kconfig
  *files* declaring them are, so "everything under `drivers/usb`" is a well-defined
  set. It emits `driver-modules.nix` as `option module` entries — the `NAME? m`
  form that is skipped on unmet dependencies rather than failing the build.
  Regenerate on any kernel version bump.

### 6.3 What turning autoModules off exposes

Three times now, `autoModules = false` has revealed a dependency nixpkgs was
silently supplying. Expect a fourth.

- **`boot.initrd.includeDefaultModules = false`.** The default initrd module list
  is PC hardware — `ata_piix`, `sata_via`, `nvme`, `xhci_hcd`. None exists here and
  `make-initrd` fails outright. The whole USB -> SCSI -> ext4 path is built in
  instead, which removes a class of failure entirely.
- **Netfilter.** common-config enables `NF_TABLES_INET`, `NF_TABLES_IPV4` and
  friends but never `NF_TABLES` itself, so the firewall died with
  `iptables: Failed to initialize nft: Protocol not supported`. `NF_TABLES` and
  `NF_CONNTRACK` are built **in**; the rest comes as modules via the scoped paths.
  **`NFT_COMPAT` must be `module`, not `yes`** — it depends on `NETFILTER_XTABLES`,
  which is `m`, so kconfig offers only `N/m`; answering `y` makes it re-ask and
  `generate-config.pl` dies with `repeated question ... line 94` followed by a wall
  of `Error in reading or end of file.` The wall is the symptom, not the cause.
- **`SCHED_CLASS_EXT = no`.** nixpkgs enables sched_ext for anything with an eBPF
  JIT, but `kernel/sched/ext.c` references `stop_sched_class` unconditionally while
  `build_policy.c` only compiles `stop_task.c` under `CONFIG_SMP`. The 88F6281 is
  single-core, so `SMP=n` is right and sched_ext is what has to go.

### 6.4 Device tree

No custom DTS is needed to boot: `kirkwood-ds409.dts` already declares
`synology,ds410j` and the kernel reports `Machine model: Synology DS409, DS410j`.

**`hardware.deviceTree.name = "kirkwood-ds409.dtb"` — no `marvell/` prefix.** The
kernel source keeps it under `arch/arm/boot/dts/marvell/`, but the directory NixOS
ships in `/boot` is **flat**. Nothing catches a wrong name at build time; it
surfaces only as U-Boot failing to load the FDT. Re-check against a built image
after any kernel bump.

A custom `kirkwood-ds410j.dts` is still wanted for three defects (§7.1).

---

## 7. Open work

### 7.1 Board integration

- **Fan control.** Currently *pinned*, not controlled: U-Boot holds 3300 rpm and
  nothing varies it with temperature. Needs (a) `gpio-fan-150-15-18` to probe —
  it fails at `setup of GPIO alarm failed: -524`, so dropping `alarm-gpios` in a
  custom DTS is the obvious first try [VERIFY] — and (b) a userspace daemon
  polling drive SMART temps, since there is no hwmon (§3.3). On a 4-bay box with
  3 TB drives this is a correctness issue, not polish.
- **A `kirkwood-ds410j.dts`**, for three defects `ds409.dts` has on this board:
  1. `kirkwood-synology.dtsi` enables the SoC's native `sata@80000` with
     `nr-ports = <2>`, claiming MPP20, which `eth1` also wants — `pin PIN20 already
     requested by f1080000.sata`. Those ports are unpopulated here. Disabling the
     node frees the pin. Related: `ds409.dts` enables `&eth1`, but `ethphy1` is
     absent on this board and the wired port is `eth0`, so that looks simply wrong.
  2. `local-mac-address` — without it `eth0` comes up as `00:00:5f:ff:00:00`.
  3. the `gpio-fan` probe failure above.
  Cosmetic: the SPI flash node says `st,m25p80` for an M25P32; `jedec,spi-nor`
  probes it anyway.
- **Reboot.** §3.3. `orion_wdt` loads but its restart handler does not take effect.
  Since `poweroff` *does* work through the board's microcontroller, the likely
  avenue is that the same MCU accepts a reset command — worth tracing what the
  Synology variant of `POWER_RESET_QNAP` does [VERIFY]. For a headless 24/7 NAS
  this matters as much as poweroff did.
- **LEDs and the reset button.** `gpio-leds` and `gpio-keys` nodes exist in
  `kirkwood-synology.dtsi`; `ds409.dts` enables the HDD and alarm LEDs. Untested.
- **CESA and `mv_xor`.** Untested. CESA matters for §7.2.

### 7.2 LUKS

Wanted: encrypted data volumes on the SATA array. Several things about this box
make it more interesting than usual, and they should be settled *before* formatting
anything, because two of them are baked in at `luksFormat` time.

- **Argon2 memory cost is the trap.** LUKS2 defaults benchmark the KDF on the
  *formatting* machine. Format on an x86_64 box with gigabytes free and the header
  can demand far more memory than this board has, at which point it simply cannot
  be unlocked here. Format with an explicit cap — `--pbkdf-memory` in the tens of
  MB, iterations tuned to taste — or use `pbkdf2`. Verify by unlocking on the
  device, not on the build host. [VERIFY] what actually fits in 118 MB alongside
  the rest of userspace.
- **Cipher choice should follow CESA.** CESA accelerates AES **CBC/ECB**, not XTS
  [VERIFY]. dm-crypt's default `aes-xts-plain64` would therefore run in software on
  a 800 MHz ARMv5 — likely well under the 12.5 MB/s the 100 Mb/s link can carry,
  making crypto the bottleneck. `aes-cbc-essiv:sha256` should let CESA do the work.
  Measure both before committing; the difference decides whether the NAS is usable.
- **Encrypt data, not root — and the initrd problem disappears.** If root stays
  unencrypted on the USB stick and only the array is encrypted, unlocking happens
  in ordinary userspace via systemd-cryptsetup, with no initrd involvement at all.
  That sidesteps the deprecated scripted initrd (§6.2) entirely. Encrypting root
  would instead force either the scripted initrd (going away) or the systemd initrd
  (which did not fit in RAM) — so prefer data-only unless there is a reason not to.
- **Headless unlock.** Options, in increasing order of effort: a keyfile on the USB
  boot stick (protects against drive theft, not chassis theft); manual entry over
  serial or ssh after boot; network unlock in initrd (needs networking in the
  initrd — heavy here, and moot if root is unencrypted).

### 7.3 Smaller items

- **`boot.initrd.enable = false`.** The durable fix for §6.2's deprecation warning,
  and it removes the initrd from the RAM budget entirely. The USB -> SCSI -> ext4
  path is already built in; what remains is `root=` on the cmdline plus
  `init=/nix/var/nix/profiles/system/init` — a store-independent path, which is what
  lets a baked-in cmdline survive generation switches.
- **Generation rollback from the extlinux menu.** Untested — only one generation
  exists so far, so the menu has nothing to roll back to.
- **`nixos-rebuild --target-host`** — build on x86_64, activate on the device.
  Note this conflicts with `system.switch.enable = false` (§6.1); decide which
  matters more.
- **Port the PCI 88SX7042 into U-Boot's `sata_mv`.** Same EDMA design behind a PCI
  BAR, and `sata_mv.c` already handles Gen-IIE — plausibly a few hundred lines. It
  would remove the USB dependency entirely.
- **Upstream the `kirkwood-ds410j.dts`** once it exists.
