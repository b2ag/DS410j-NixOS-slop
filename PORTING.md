# NixOS on Synology DS410j — Porting Brief

Target: mainline Linux + NixOS on a Synology DS410j (Marvell Kirkwood 88F6281, armv5tel, 128 MB RAM).

Status: **M1-M3 complete; the go/no-go gate is passed.** A mainline 6.12.104 kernel
TFTP-boots into RAM, reaches a serial shell, drives both fitted SATA bays at 3.0 Gbps
through the PCIe controller, and has a working ethernet link. See section 10 for the
bring-up log and the corrections it forced on this document.

Two of the three "hard parts" turned out not to exist: the DTS is already in mainline,
and the bootloader is U-Boot rather than RedBoot. RAM (118 MB) remains a real constraint.

---

## 0. Read this first: rules that must not be broken

- [ ] **Never write to `mtd0`.** It lives at flash offset 0 and is the only recovery
      path short of a SOIC clip on the flash chip. Note the partition is *labelled*
      "RedBoot" but actually contains **Marvell U-Boot 1.1.4** - see section 10.
      In practice this means: **never run `bubt`**, the vendor's "Burn an image on the
      Boot Flash" command. It is the one command that can brick this box.
- [ ] ~~Never run RedBoot's `fis init`.~~ **Not applicable** - there is no RedBoot and
      no FIS directory in use. The `fis`-named MTD partitions are inherited Synology
      labels, nothing parses them.
- [ ] **Back up all six MTD partitions before touching anything.** See §7.
- [ ] **Serial console must be attached and working before the first flash write.**
      3.3 V TTL on the internal header, 115200 8N1. A bricked bootloader with no UART is
      a paperweight.
- [ ] **`bootdelay` is 3 s and cannot be changed persistently** - this U-Boot has no
      `saveenv` (verified: `Unknown command 'saveenv'`). All `setenv` changes are
      RAM-only, which is a useful safety property: a power cycle always returns to a
      known-good stock configuration.
- [ ] **Do not replace the stock U-Boot.** A newer U-Boot goes in the freed `zImage`
      slot as a chainloaded secondary, reached with `go`. See §5.
- [ ] **Never run `nix` evaluation on the device.** 118 MB will OOM the evaluator. All
      builds cross-compile on x86_64. See §6.

### Confidence markers used below

- **[CONFIRMED]** — verified from the DSM diagnostic dump (§7 has the raw source).
- **[LIKELY]** — strong inference, not verified.
- **[VERIFY]** — must be checked against the actual kernel/U-Boot tree or the hardware
  before being relied on. Several of these come from recollection of trees as of
  ~May 2026 and may be wrong or stale. Do not let an unverified claim in this document
  become a load-bearing assumption.

---

## 1. Hardware baseline

| Item | Value | Source |
|---|---|---|
| SoC | Marvell Kirkwood 88F6281, Feroceon 88FR131 rev 1, ARMv5TE | [CONFIRMED] |
| Clock | ~800 MHz (794 BogoMIPS) | [CONFIRMED] |
| RAM | 118464 kB usable, soldered, not expandable | [CONFIRMED] |
| Bootloader | **Marvell U-Boot 1.1.4** (Mar 17 2010), Marvell version 3.4.4 | [CONFIRMED] |
| Flash | 4 MB, 64 KB erase blocks, **NOR** (no NAND in dmesg) | [CONFIRMED] |
| Flash bus | SPI NOR via `spi-orion` + `m25p80`; chip is **ST M25P32**, 64x64 KB | [CONFIRMED] |
| SATA | **PCIe Marvell 88SX7042** (`11ab:7042` rev 02), Gen-IIE, 4 ports | [CONFIRMED] |
| SATA (unused) | SoC's 2 native ports present but unpopulated (`ata5`/`ata6`) | [CONFIRMED] |
| Port multiplier | **None.** Risk area eliminated. | [CONFIRMED] |
| Ethernet | Integrated Kirkwood GbE, `mv643xx_eth`, wired port is **eth0** | [CONFIRMED] |
| PHY | on eth0, link negotiates 100 Mb/s full duplex. `ethphy1` (MDIO addr 9) is **absent** | [CONFIRMED] |
| Crypto | CESA present (`cesa_ocf_drv` loaded under DSM) | [CONFIRMED] |
| USB | 2x USB 2.0, `ehci-orion` probes, 4-port hub detected | [CONFIRMED] |
| hwmon | **None.** `/sys/class/hwmon` is empty; no on-board temp sensor. | [CONFIRMED] |
| Fan / LEDs / poweroff | All inside the proprietary `ds410j_synobios` module | [CONFIRMED] |
| Disks | bay->port is 1:1 (bay1=`ata1`, bay3=`ata3`). Drive power is **not** GPIO-gated | [CONFIRMED] |

### Notes on the surprises

The `sky2` module loaded under DSM is almost certainly spurious init cruft — no Yukon
device appears on the PCI bus. Confirm in §7 but don't plan around it.

Because `/sys/class/hwmon` is empty, there is **no temperature sensor on this board at
all**. DSM reads drive SMART temps and drives the fan over GPIO from userspace. Both the
GPIO mapping and the control policy have to be supplied by us. See §4 (fan).

---

## 2. Flash layout

### Stock (from `/proc/mtd`) [CONFIRMED]

| Partition | Offset | Size | Name |
|---|---|---|---|
| mtd0 | 0x000000 | 512 K | RedBoot |
| mtd1 | 0x080000 | 2 M | zImage |
| mtd2 | 0x280000 | 1.25 M | rd.gz |
| mtd3 | 0x3C0000 | 64 K | vendor |
| mtd4 | 0x3D0000 | 128 K | RedBoot Config |
| mtd5 | 0x3F0000 | 64 K | FIS directory |

The `zImage` and `rd.gz` slots are **adjacent**, giving 3.25 MB contiguous
(0x080000–0x3C0000) once the stock initrd is abandoned.

### Target

| Range | Size | Contents |
|---|---|---|
| 0x000000–0x080000 | 512 K | RedBoot. **Never written.** |
| 0x080000–0x180000 | 1 M | `u-boot` (expect ~600–800 K, leaves headroom) |
| 0x180000–0x190000 | 64 K | `ubootenv` — *optional, see §5* |
| 0x190000–0x3C0000 | 2.4 M | `kernel-fallback`, directly RedBoot-bootable |
| 0x3C0000–0x400000 | 256 K | vendor + RedBoot Config + FIS directory. Keep. |

Rationale: two independent recovery paths (RedBoot→kernel direct, and
RedBoot→U-Boot→USB), plus room for U-Boot to grow. All offsets must be 64 KB-aligned.

Linux has a RedBoot FIS partition parser (`CONFIG_MTD_REDBOOT_PARTS`,
`compatible = "redboot-fis"`, `fis-index-block` property), so re-carving the FIS
directory makes the kernel's own MTD partition list follow automatically. [VERIFY] the
exact binding property names against the tree.

---

## 3. The three hard constraints

### 3.1 Kernel slot is 2 MB (3.25 MB after re-carving)

A mainline `mvebu_v5_defconfig` zImage exceeds 2 MB. Mitigations: aggressive config
trimming (§4), `CONFIG_KERNEL_XZ`, nothing built in that isn't needed to reach root.
Expect 1.8–2.5 MB — genuinely marginal at 2 MB, comfortable at 3.25 MB.

### 3.2 Initrd slot is 1.25 MB

A NixOS stage-1 initrd is 15–40 MB. No amount of trimming closes an order-of-magnitude
gap. Two answers, in order of preference:

**Preferred (needs U-Boot + USB):** full-size kernel and full stage-1 initrd on a USB
`/boot`, `boot.loader.generic-extlinux-compatible.enable = true`. This is the *supported*
NixOS path — real generation menu, working rollback, a code path other people exercise.

**Fallback (RedBoot only):** no initrd at all.

```nix
boot.initrd.enable = false;
```

Root is a plain ext4 partition; PCI + `sata_mv` + ext4 are built into the kernel. Boot
with:

```
root=/dev/sda2 rw init=/nix/var/nix/profiles/system/init
```

The store-independent profile path is the trick that makes this survive generation
switches: a cmdline baked into flash still picks up new generations via the profile
symlink. You lose the boot-time generation picker but keep rollback semantics.

### 3.3 118 MB of RAM

- No nix evaluation on device, ever. Cross-compile on x86_64.
- Keep the existing 2 GB swap partition; add zram on top.
- Minimal systemd unit set, no X, journald volatile and size-capped.
- A *running* (not building) minimal NixOS in 118 MB has precedent (Debian armel), but
  it is tight.

---

## 4. Kernel

Base config: `mvebu_v5_defconfig`, then trim hard. Pin an **LTS** (6.6 or 6.12) — ARMv5
platforms are where mainline regressions go unnoticed for a release or two. Don't chase
latest.

### Must be built in (not modules — nothing loads them before root)

- [ ] `CONFIG_ARCH_MVEBU`, `CONFIG_MACH_KIRKWOOD`, `CONFIG_ARCH_MULTI_V5`
- [ ] `CONFIG_ARM_APPENDED_DTB` — nothing in the RedBoot chain understands FDT
- [ ] `CONFIG_KERNEL_XZ`
- [ ] **`CONFIG_KUSER_HELPERS=y`** — ARMv5TE has no LDREX/STREX; userspace atomics go
      through `kuser_helper`. Without it every glibc binary breaks in baffling ways.
      Some hardening profiles disable this — **check that NixOS's kernel config and any
      hardened profile aren't turning it off.**
- [ ] `CONFIG_PCI` + Kirkwood PCIe host support — the 88SX7042 is *behind PCIe*. Easy to
      forget on a board where you think of SATA as on-SoC. [VERIFY] which symbol;
      `PCI_MVEBU` is written for Armada and may not cover Kirkwood.
- [ ] `CONFIG_SATA_MV` (PCI path), `CONFIG_EXT4_FS`
- [ ] `CONFIG_MV643XX_ETH`, `CONFIG_MARVELL_PHY`

### Wanted, can be modules

- [ ] `CONFIG_MTD_REDBOOT_PARTS`, `CONFIG_SPI_ORION`, `CONFIG_MTD_SPI_NOR`
      (or `CONFIG_MTD_PHYSMAP` / `CONFIG_FLASH_CFI` if the NOR turns out to be parallel
      on the device bus — resolve via §7)
- [ ] `CONFIG_SENSORS_GPIO_FAN`
- [ ] `CONFIG_POWER_RESET_GPIO` / `CONFIG_POWER_RESET_QNAP` (see poweroff below)
- [ ] `CONFIG_LEDS_GPIO`, `CONFIG_I2C_MV64XXX`, **`CONFIG_RTC_DRV_RS5C372`**
      (the RTC is a Ricoh `rs5c372a`, not the `s35390a` guessed earlier - `ds409.dts`
      is right and it keeps time across power cycles) [CONFIRMED]
- [ ] `CONFIG_USB_EHCI_HCD_ORION`, `CONFIG_USB_STORAGE`
- [ ] `CONFIG_CRYPTO_DEV_MARVELL_CESA`, `CONFIG_MV_XOR` — CESA meaningfully helps
      dm-crypt and SSH throughput on a 800 MHz ARMv5
- [ ] `CONFIG_KEXEC` — optional, enables the shim approach if ever needed

Everything else goes. That's where the 2 MB comes from.

### ARMv5TE landmines (beyond KUSER_HELPERS)

- **No ARM vDSO** (ARMv7+ only). `clock_gettime` is a real syscall. Costs performance,
  breaks nothing.
- **64-bit atomics are not lock-free.** GCC lowers to `libatomic` calls; surfaces as
  link failures in packages that never needed `-latomic`.
- **Rust:** `armv5te-unknown-linux-gnueabi` reports a 32-bit max atomic width, so any
  crate touching `AtomicU64` will not compile. See §6.

### Device tree

**RESOLVED: no new DTS is needed.** `kirkwood-ds409.dts` in 6.12.104 already declares
this board explicitly [CONFIRMED]:

```
model = "Synology DS409, DS410j";
compatible = "synology,ds409", "synology,ds410j", "marvell,kirkwood";
```

It boots and is what the running kernel reports (`OF: fdt: Machine model: Synology
DS409, DS410j`). `kirkwood-ds410j.dts` is indeed absent from mainline, but is
unnecessary. `kirkwood-synology.dtsi` also enables `&pciec`/`&pcie0`, which is what
makes the four bays work.

A hand-written `kirkwood-ds410j.dts` is now only worth writing for the two defects in
§10.3 (`eth1`/native-SATA pin conflict, `local-mac-address`), not to boot the board.

- [ ] Write `kirkwood-ds410j.dts`, cross-referencing `ds409` (same 4-bay chassis, same
      88SX7042 topology) and `ds411j`.
- [ ] Fix up: fan GPIOs, LED GPIOs, HDD power-enable GPIOs, `local-mac-address`.
- [ ] Bake `chosen/bootargs` into the DTS for the RedBoot phase. Do **not** depend on
      RedBoot's cmdline mechanism or on `CONFIG_ARM_ATAG_DTB_COMPAT` — treat the latter
      as a bonus.
- [ ] MAC address lives in RedBoot config or the `vendor` partition, nowhere the kernel
      will find it automatically. Without `local-mac-address` you get a random MAC each
      boot.

### Poweroff — get this right early

**RESOLVED.** Synology Kirkwoods send a magic byte over the **second UART** to a board
MCU rather than toggling a GPIO. `kirkwood-synology.dtsi` carries `poweroff@12100` with
`compatible = "synology,power-off"` (0x12100 is UART1), and
`drivers/power/reset/qnap-poweroff.c` matches that string alongside `qnap,power-off`.
`CONFIG_POWER_RESET_QNAP=y` is already in `mvebu_v5_defconfig`. [CONFIRMED]
Not yet functionally tested - do that before relying on it.

A "shutdown" that halts with the fan stopped and drives spinning is how you lose a disk.
This is a correctness issue, not a polish item.

### Fan — must-have, not nice-to-have

`gpio-fan` handles multi-GPIO discrete-speed Synology fans, but with **no hwmon device on
this board there is nothing to drive it from**. Plan: a small userspace daemon polling
drive temps via `smartctl`.

**For v1, pin the fan at a safe mid speed and don't be clever.** No fan control on a
4-bay box means cooked drives.

---

## 5. Bootloader

### Phase 1 — RAM boot over TFTP, zero flash writes — **DONE**

This is the development loop. No brick risk. The stock U-Boot has `tftpboot`, so the
RedBoot `load`/`exec` sequence originally written here does not apply. What works:

```
setenv ipaddr 192.168.50.50
setenv serverip 192.168.50.1
setenv netmask 255.255.255.0
tftpboot 0x04000000 uImage-hi
bootm 0x04000000
```

Wrap `zImage` + appended DTB as a **uImage** (this U-Boot has no `bootz`):

```
cat zImage arch/arm/boot/dts/marvell/kirkwood-ds409.dtb > zImage-dtb
mkimage -A arm -O linux -T kernel -C none -a 0x02000000 -e 0x02000000 -d zImage-dtb uImage-hi
```

**The load address matters and cost a hang to discover.** U-Boot relocates itself to
`0x00600000`–`0x0068B3B4` and reserves the low 8 MB (`Addresses 8M - 0M are saved for
the U-Boot usage`). `bootm` memmoves the payload to the uImage load address, so a
conventional `-a 0x00008000` with an image larger than ~5.9 MB **overwrites U-Boot's own
running code mid-copy** and wedges the CPU with no output — the symptom is that
`Verifying Checksum ... OK` prints and `Starting kernel ...` never does. A zImage is
position-independent, so load high (`0x02000000`) and let the decompressor place the
kernel itself. Build `mkimage` output on local disk, not on a 9p mount: `mkimage` needs
`mmap` and fails with `Can't map ... Invalid argument`.

Note `CONFIG_ARM_ATAG_DTB_COMPAT` is active in `mvebu_v5_defconfig`, so **U-Boot's
`bootargs` override the DTS `chosen/bootargs`**. Useful for iterating without a rebuild;
it also means the stock `initrd=0x00800040,4M` leaks in and produces a harmless
`INITRD: ... overlaps in-use memory region - disabling initrd`. Override with
`setenv bootargs`.

### Phase 2 — a newer U-Boot chainloaded from the stock U-Boot

The shape of this plan survives the bootloader correction, with RedBoot replaced by the
stock U-Boot: the stock loader stays at offset 0 untouched as the recovery path, and a
newer U-Boot goes in the freed `zImage` slot, entered with `go`.

**Two facts now make this the only route to unattended configurability:**

1. **There is no `saveenv`.** Env changes never persist, so `bootcmd` cannot be
   repointed. The stock `bootcmd=bootm F8080000 F8280000` is therefore the *only*
   unattended hook, and it reads the `zImage` slot at flash offset 0x80000.
   Anything we want to run without a human at the console must live there.
2. **The stock U-Boot cannot boot from USB at all** — no `usb`, `fatload`, `ext2load`,
   `ext4load`, `fdt` or `bootz` commands (verified against `help`). It initialises USB
   in host mode but has no storage commands. USB `/boot` *requires* the newer U-Boot.

Writing the `zImage` slot is low-risk: if the payload is bad, the stock U-Boot at
offset 0 still comes up and TFTP still works. Only `bubt` is dangerous.

**The catch that shapes the rest of this section:** the newer U-Boot almost certainly
**cannot see the drive bays**. U-Boot's `sata_mv` targets the *SoC-integrated* Kirkwood/Orion controllers;
there is no known U-Boot driver for the PCI 88SX50xx/60xx/7042 family. Stacked underneath
is a second question: whether mainline U-Boot has Kirkwood *PCIe host* support at all
(`pci_mvebu.c` is written for Armada; a Kirkwood equivalent may not exist). [VERIFY]
both before committing. If PCIe is absent, SATA is blocked twice over.

What U-Boot *can* read here:

| Device | Driver | Use |
|---|---|---|
| USB | `ehci-marvell.c` + USB storage + ext4 | **`/boot` on a stick** |
| Ethernet | `mvgbe.c` | TFTP / PXE, great for dev |
| NOR | `kirkwood_spi.c` + `m25p80` [VERIFY] | Same 3.25 MB ceiling, no gain |
| SATA bays | — | **Not available** |

So: **`/boot` goes on a USB stick.** That removes the flash budget entirely and unlocks
`generic-extlinux-compatible` (§3.2). Root stays on the array; the initrd carries the
PCI + `sata_mv` drivers to find it.

Costs: a USB stick is a new failure mode on a 24/7 box and cheap ones die. `/boot` is
read-mostly so it's not terrible. Use a decent stick, keep an image of it, and rely on
the NOR `kernel-fallback` slot when it fails.

#### Build

- [ ] Start from `configs/ds109_defconfig` (Synology, same 88F6281) if still in tree,
      else `sheevaplug_defconfig`. [VERIFY]
- [ ] Add USB storage, ext4, FDT, PCIe if available.
- [ ] Package with `buildUBoot` in nixpkgs. Cross-compiling U-Boot to armv5 is easy and
      has none of the Rust / 64-bit-atomic problems that bite userland.
- [ ] Build **`u-boot.bin`, not `u-boot.kwb`.** The `.kwb` wrapper exists for the SoC
      BootROM and includes a DDR register-init list. RedBoot has already initialized
      DRAM, and Kirkwood's `dram_init` only *reads* the SDRAM decode registers rather
      than reprogramming them, so entering U-Boot proper on an initialized system should
      be fine.
- [ ] **Strongly consider `CONFIG_ENV_IS_NOWHERE` with a compiled-in default env.** It
      removes all risk of a miscalculated env offset scribbling on the FIS directory or
      RedBoot config, and makes the boot environment part of a Nix derivation rather
      than mutable flash state. Very much in the spirit of the exercise. If you do want
      a writable env, resolve the SPI-vs-parallel-NOR question first (§7) — you need the
      matching driver either way.
- [ ] U-Boot needs its own DTB via `CONFIG_OF_CONTROL`, but only cares about UART, SPI,
      GbE and USB nodes. **Reuse ds109 or ds411j for U-Boot; keep the hand-written
      `kirkwood-ds410j.dts` as the Linux DTB on `/boot`. Do not couple the two.**

#### Test, then commit

```
load -v -r -b 0x00800000 -h <tftp-server> u-boot.bin
go 0x00800000
```

Use **`go`, not `exec`** — `exec` is RedBoot's Linux-specific path and sets up ATAGs and
a machine number; U-Boot wants a plain jump and establishes its own stack. Check
`help go` for the flag spelling on this build.

```
fis create -b 0x00800000 -l 0x100000 -f 0x00080000 -e 0x00800000 u-boot
fconfig    # boot_script: fis load u-boot; go
```

**Debug note:** if you get an immediate hang with no U-Boot banner, suspect cache/MMU
state at handoff. RedBoot may hand off with MMU and I/D caches enabled and Feroceon has
an L2; U-Boot's `arm926ejs` start path is supposed to tear that down.

### Rejected alternatives

- **Replacing the stock U-Boot (via `bubt`)** — destroys the only recovery path for no
  benefit. The stock U-Boot already does everything needed to chainload.
- **kexec shim** (tiny flashed kernel with built-in initramfs that kexecs the real
  kernel from disk) — was the pre-U-Boot plan. Still viable as a *third* fallback since
  `CONFIG_KEXEC` works on ARMv5, and it's the only option that boots a full initrd
  *without* USB. Keep in reserve if the U-Boot USB path disappoints.

---

## 6. NixOS / nixpkgs

- **Cross entry point:** `pkgsCross.sheevaplug` — `armv5tel-unknown-linux-gnueabi`, and
  the SheevaPlug is also an 88F6281. Exact platform match.
- **No binary cache for armv5tel and Hydra does not build it.** Everything from source.
  Cross-compiling from x86_64 makes this tolerable; native building does not.
- **Rust is the main userland blocker.** Modern NixOS defaults to
  `switch-to-configuration-ng`, which is Rust, and `armv5te` has a 32-bit max atomic
  width. Set:

  ```nix
  system.switch.enableNg = false;   # fall back to the Perl implementation
  ```

  Apply the same caution to any Rust anywhere in the closure. Keep Rust off the critical
  path for v1.
- **systemd** is the other thing to derisk early in the cross closure.
- **Encouraging precedent:** Debian armel targeted ARMv5TE and shipped glibc + systemd +
  a full userland for years. Nothing in a minimal NixOS closure is fundamentally
  impossible on this ISA. Debian *also* dropped the `marvell` kernel flavour and declared
  128 MB devices unable to run the installer — read that as a warning about **memory**,
  not about the ISA.
- **Deployment model for v1:** build a full disk image on x86_64 (`make-disk-image` or an
  sdImage-style derivation), write it to a drive from another machine, boot it. Closure
  *copying* via `nixos-rebuild --target-host` may survive 118 MB; evaluation must never
  happen on-device. On-device nix is a stretch goal, not a milestone.
- **Memory config:** zram swap, keep the 2 GB disk swap, minimal unit set, journald
  volatile and size-capped.

---

## 7. Diagnostics

### 7.1 Do this first — back up the flash

```sh
for i in 0 1 2 3 4 5; do dd if=/dev/mtd$i of=/volume1/backup/mtd$i.bin bs=64k; done
md5sum /volume1/backup/mtd*.bin
```

Then scp them off the box, checksum again at the destination, and keep them somewhere
you'll still have them in a year. **Two copies.**

### 7.2 Open questions and the commands that close them

Note: `strings` is not present on DSM's busybox — use the `tr` substitute below.

```sh
# HIGHEST VALUE: RedBoot config = load addresses, boot script syntax,
# current bootargs, and probably the MAC. Otherwise all reverse-engineered
# by trial and error at the serial prompt.
dd if=/dev/mtd4 bs=64k | tr -cs '\11\12\40-\176' '\n' | head -80
dd if=/dev/mtd3 bs=64k | tr -cs '\11\12\40-\176' '\n' | head -40   # vendor partition

# Flash controller: SPI NOR or parallel NOR on the device bus?
# Decides m25p80 vs CFI, in both Linux and U-Boot.
dmesg | egrep -i 'spi|m25p|physmap|mtd|flash|jedec'

# Confirm the NIC is integrated GbE (not sky2) and capture the MAC
ifconfig eth0 | head -2
dmesg | egrep -i 'eth0|egiga|mv_eth|yukon|phy'

# Anything GPIO- or sensor-visible that synobios exposes
ls /sys/class/gpio /proc/sys/dev 2>/dev/null
cat /proc/interrupts
```

Unknowns to resolve, tracked:

- [x] ~~RedBoot config contents~~ — no RedBoot. Stock U-Boot env captured from the
      serial console. Env is blank (`Using default environment`) and cannot be
      written (no `saveenv`).
- [x] **SPI NOR**, not parallel. `flinfo` reports `ST M25P32`, mfr 0x20, dev 0x2016,
      64 x 64 KB sectors, read-mapped at 0xf8000000. Linux: `spi-nor spi0.0: found
      m25p32, expected m25p80` — the DTS `compatible` is cosmetically wrong, harmless.
- [x] **Ethernet**: `mv643xx_eth` on **eth0**. Link up 100 Mb/s full duplex, ping to
      host 3/3 packets, 0% loss, 0.56 ms avg.
- [x] **MAC address = `00:11:32:02:f9:a6`**, at offset 0 of the `vendor` partition
      (mtd3), Synology OUI `00:11:32`. Unit serial `A5G7N01773D` at offset 0x20.
      `mtd4` contains no MAC. The kernel does *not* find this by itself — it comes up
      with U-Boot's placeholder `00:00:5f:ff:00:00`, so `local-mac-address` is needed.
- [x] **`kirkwood-ds410j.dts` is absent but unnecessary** — `ds409.dts` declares
      `synology,ds410j`. See §4.
- [x] **Kirkwood PCIe host support exists** in both: the stock U-Boot enumerates the
      bus (`PEX interface detected Link X1`, `pci` lists `11ab:7042`), and Linux's
      `PCI_MVEBU` matches `marvell,kirkwood-pcie`. The *newer* U-Boot's PCIe support is
      still [VERIFY], but is only needed for the §7 M7 SATA-in-U-Boot stretch goal.
- [x] **Poweroff is UART-to-MCU** (`synology,power-off` on UART1). See §4.
- [ ] Fan GPIO mapping — `gpio-fan-150-15-18` fails to probe: `setup of GPIO alarm
      failed: -524`. **Lower priority than §4 implies**: the case fans run continuously
      from hardware default, so a failed probe costs control, not cooling.
- [x] **HDD power is not GPIO-gated.** All six `regulators-hdd-*` groups are `disabled`
      and drives spin up regardless. Do not enable them.

---

## 8. Milestones

The gate is **M3**. Everything before it is reversible; M3 is where we learn whether this
works.

### M1 — Safety net
- [x] Serial console attached, bootloader prompt reachable, 115200 8N1
      (`/dev/ttyS1`, prompt is `Marvell>>`)
- [x] **All six MTD partitions backed up, off-box, checksummed twice.** Dumped from
      the running mainline kernel over ethernet (`nc` from `/dev/mtdN` -> `socat`
      listener); device-side md5 compared against host-side md5, all six byte-exact;
      md5 + sha256 manifest in `flash-backup/CHECKSUMS.txt`. Two copies:
      `/src/flash-backup` and `/src/flash-backup-copy2`, both on the host mount, which
      survives VM resets. Reproduce with `kernel/dump-flash.sh`.
- [x] Bootloader `version`, `printenv`, `flinfo`, `pci`, `help` captured from the
      serial console; the load-bearing values are quoted in §7.2 and §10.1.
      (`fis list`/`fconfig` do not exist — no RedBoot.)

### M2 — Understand the boot chain
- [x] Boot chain documented: `bootcmd=bootm F8080000 F8280000`, i.e. kernel from flash
      offset 0x80000 and initrd from 0x280000, via the read-mapped NOR window at
      0xf8000000. `bootdelay=3`. Env is blank and unwritable (no `saveenv`).
- [x] Flash controller resolved: **SPI NOR, ST M25P32** (see §7.2).
- [x] TFTP server up and reachable (`ping` -> `host 192.168.50.1 is alive`;
      `tftpboot` transferred 7,223,568 bytes byte-exact).

### M3 — GO/NO-GO GATE: mainline kernel boots — **PASSED**

- [x] Existing mainline DTS confirmed: `kirkwood-ds409.dts` declares `synology,ds410j`;
      kernel reports `OF: fdt: Machine model: Synology DS409, DS410j`.
- [x] Kernel + appended DTB TFTP'd into RAM, `bootm`'d, reaches a busybox serial shell
      (Linux 6.12.104, `armv5tel`, 114 MB of 128 MB available).
- [x] SATA through PCIe + `sata_mv`: `pci 0000:01:00.0: [11ab:7042]` ->
      `sata_mv: Gen-IIE 32 slots 4 ports`. All four ports instantiated as `ata1`-`ata4`.
      Both fitted drives link at **3.0 Gbps** (bay1=`ata1`=`sda`, bay3=`ata3`=`sdb`,
      Toshiba DT01ACA300 3 TB, partitions read). Bays 2 and 4 are empty and report
      link-down cleanly. Bay->port mapping is 1:1.
- [x] Ethernet up: `eth0` link 100 Mb/s full duplex, ping 3/3, 0% loss, 0.56 ms avg.
- [x] **zImage size measured.** Trimmed, XZ, no initramfs (`-A kernelMin`):
      **zImage 3,034,144 + DTB 21,312 = 3,055,456 bytes (2.91 MiB)**.
      - 2 MB stock slot (2,097,152): **OVER by 935 KiB** — does not fit.
      - 3.25 MB re-carved slot (3,407,872): **FITS with 344 KiB spare.**

      For comparison the gzip bring-up image with embedded busybox initramfs is
      7,223,504 bytes. So compression is viable, *but only with the §2 re-carve* —
      and see §10.5, which constrains the layout more than §2 currently assumes.

### M4 — Board integration
- [~] **Fan pinned at a safe speed, but NOT controllable.** U-Boot's `board_init()`
      now holds GPIO0 15/16/17 at 3300 rpm (§12.2) - required, because our U-Boot
      was otherwise switching the fans off and Linux never turned them back on.
      Still nothing varies speed with temperature: there is no hwmon on this board
      and `gpio-fan-150-15-18` still fails to probe (§10.3). Fixing that probe is
      what would make this a tick rather than a workaround.
- [x] **Poweroff actually powers off** — `systemctl poweroff` cuts power for real
      (observed at the bench). Note the asymmetry with reboot (§14.1): poweroff
      works, the SoC reset does not.
- [ ] **Warm reboot works.** `reboot -f` under 6.12.104 prints
      `reboot: Restarting system` and then hangs the board dead - a power cycle is the
      only recovery. `orion_wdt` loads (`Initial timeout 21 sec`) but its restart
      handler does not take effect, and `POWER_RESET_QNAP` covers poweroff only.
      For a headless 24/7 NAS this is as important as poweroff. [CONFIRMED]
- [ ] Reset button, LEDs
- [ ] Correct MAC via `local-mac-address`
- [ ] RTC keeps time across a power cycle
- [ ] CESA and mv_xor probe

### M5 — NixOS closure
- [x] **Minimal cross NixOS config evaluates** (`nixos/`, §11). `nixpkgs.hostPlatform =
      { config = "armv5tel-unknown-linux-gnueabi"; }` - the same attrset as
      `pkgsCross.armv5tel-multiplatform`, so the cached x86_64 cross toolchain is
      reused. (`pkgsCross.sheevaplug` no longer exists.)
- [x] **No Rust in the closure** - but *not* via `system.switch.enableNg`, which
      nixpkgs 26.11 has removed; `system.switch.enable = false` replaces it (§11.1).
      Verified against the dry-run: the only Rust in the build set is `rust-bindgen`,
      a build-time x86_64 tool, and the armv5tel cross-rustc is *fetched* prebuilt
      rather than built.
- [x] **Image builds** (§11.6): 784 MiB, DOS label, 30 MB FAT32 + 745.7 MB ext4
      root with `/boot` inside it. Every path in `/boot/extlinux/extlinux.conf`
      verified to resolve by reading the image back with `debugfs` - zImage,
      initrd and `kirkwood-ds409.dtb`.
- [x] **Disk image written from another machine; BOOTS TO A LOGIN PROMPT** (§13).
      `Welcome to NixOS sd-card-26.11pre-git (armv5tel) - ttyS0` / `ds410j login:`,
      root login works over serial.
- [x] **Runs in 118 MB; headroom measured** (§13). `free -m` reports 96 MB total,
      39 MB used, **57 MB available**, with zram providing 47 MB of swap (3 MB in
      use). Root filesystem auto-expanded to 7.4 G, 8% used.

### M6 — Unattended boot
- ~~Re-carve FIS per §2~~ **Dropped.** There is no FIS and no RedBoot (§10.1) -
      the `fis`-named partitions are inherited Synology labels with nothing behind
      them, so there is nothing to re-carve. The stock layout was used as-is:
      U-Boot in mtd1, ramdisk stub in mtd2, environment in mtd4.
- ~~`kernel-fallback` flashed and RedBoot-bootable with no host present~~
      **Dropped.** This predates the chainload design. mtd1 now holds our U-Boot,
      and the largest contiguous free region left is ~1.6 MB against a 2.9 MiB
      `kernelMin` (§11.5), so an in-flash fallback kernel does not fit anyway.
      Its purpose - booting with no host present - is served by the USB path,
      which §14.2 demonstrates. Redundancy comes from the two-stage bootloader
      chain instead: mtd0 still TFTP-boots if mtd1 is ever bad.
- [x] **U-Boot built and TFTP-tested via `go`** - U-Boot 2026.07 from
      `ds109_defconfig`, 386 KB, runs chainloaded with working SPI flash, USB and
      ethernet. See §10.7. (Superseded by the flash write below.)
- [x] U-Boot wrapped as an **`IH_TYPE_KERNEL`** uImage and written to the `zImage`
      slot (0x80000) so the stock `bootcmd` chainloads it unattended (§10.8 —
      *not* `IH_TYPE_STANDALONE`, which §10.5 recommended in error).
      `uboot/out/uImage-ub-kernel`, 395,488 bytes. RAM rehearsal via
      `bootm 0x04000000 0xF8280000` passed first, then **written to mtd1 and verified
      byte-for-byte (§10.11)**; mtd0 and mtd2 confirmed unchanged, write protection
      restored.
- [x] **Unattended cold boot into our own U-Boot — ACHIEVED (§10.12).** Stock
      `bootdelay=3` expires untouched, `bootm F8080000 F8280000` chainloads the
      payload from flash, U-Boot 2026.07 reaches its `=>` prompt with no host
      present. Flash re-verified `00471165` afterwards - booting writes nothing.
- [x] **Persistent environment in mtd4 and a minimal ramdisk stub in mtd2 (§10.14).**
      Both written in one unlock window. `bootcmd=usb start; bootflow scan`,
      `bootdelay=3`, correct `ethaddr`; env loads from flash with no bad-CRC warning.
      mtd2 shrank from Synology's 971 KB `rd.gz` to a 685-byte stub, reclaiming
      1,310,035 bytes.
- [x] **`/boot` on USB with `generic-extlinux-compatible`; menu works** (§14.2).
      `** Booting bootflow 'usb_mass_storage.lun0.bootdev.part_2' with extlinux`
      and the menu renders `1: NixOS - Default`.
- [ ] Rollback to a previous generation verified from the boot menu - only one
      generation exists so far, so the menu has nothing to roll back to
- [x] **Full cold-boot to SSH with nothing attached** (§14.2). Reaches a login
      prompt unattended and answers on the network: `SSH-2.0-OpenSSH_10.5`,
      ping 3/3 0% loss.

### M7 — Stretch
- [ ] Fan-control daemon driven by drive SMART temps
- [ ] `nixos-rebuild --target-host` (build on x86_64, activate on device)
- [ ] Port PCI 88SX7042 into U-Boot's `sata_mv` — same EDMA design as the integrated
      controller behind a PCI BAR, and `sata_mv.c` already handles Gen-IIE, so plausibly
      a few hundred lines. Would eliminate the USB dependency entirely.
- [ ] kexec shim as third fallback
- [ ] Upstream `kirkwood-ds410j.dts`
- [ ] On-device nix (closure copy only, never evaluation)

---

## 11. M5: cross-compiled NixOS image

`nixos/` holds the configuration. Build on x86_64 only - never evaluate nix on the
device (CLAUDE.md).

```sh
TMPDIR=/tmp/nixbuild nix-build /src/nixos -A image -o /src/nixos/result
```

`nixos/configuration.nix` sets `nixpkgs.hostPlatform = { config =
"armv5tel-unknown-linux-gnueabi"; }`, byte-identical to
`lib.systems.examples.armv5tel-multiplatform`, so the cached x86_64 *cross
toolchain* still substitutes from `cache.nixos.org` (§10.4). Target packages have
no cache and are all built from source.

The image reuses nixpkgs' own `installer/sd-card/sd-image.nix`, the same machinery
as `sd-image-armv7l-multiplatform.nix`, which needs no VM and no emulation.

### 11.1 `system.switch.enableNg` is gone — [CONFIRMED]

CLAUDE.md's documented way of keeping Rust out of the closure **no longer exists**.
In nixpkgs 26.11 the option hard-errors:

```
Failed assertions:
- The option definition `system.switch.enableNg' ... no longer has any effect;
  please remove it.
```

because the Rust `switch-to-configuration-ng` is now the only implementation.

The replacement is **`system.switch.enable = false`**, and it fits this project
better than the original did - its own docs call it "good for image based
appliances where updates are handled outside the image", which is exactly a box
that must never evaluate nix. The cost is that `nixos-rebuild` does not work on the
device, which was never possible here anyway.

Verified against the dry-run: **no target Rust is compiled.** The armv5tel
cross-`rustc` is *fetched* prebuilt; the only Rust in the build set is
`rust-bindgen`, an x86_64 build-time tool.

Rust also tries to re-enter sideways: `nixos-generate-config` references
`bcachefs-tools`, which is Rust. The `system.tools.nixos-*` scripts are therefore
all disabled - they cannot work on a machine that cannot evaluate nix.

### 11.2 The atomics wall is not Rust-specific — [CONFIRMED]

ARMv5TE predates ARMv6's `LDREX`/`STREX`; all it has is `SWP`, a 32-bit swap. So
there is no hardware 64-bit atomic, which is the same root cause as the mandatory
`CONFIG_KUSER_HELPERS=y`. The toolchains diverge on what to do about it:

- **C/C++** degrades quietly - GCC emits out-of-line calls into `libatomic`, which
  uses a hashed lock table. Correct, just not lock-free, and you must link
  `-latomic`.
- **Rust** refuses. Confirmed directly against the cross compiler in the store:

  ```
  $ rustc --print cfg --target armv5te-unknown-linux-gnueabi | grep has_atomic
  target_has_atomic="8"   "16"   "32"   "ptr"      <- no "64"
  ```

  `AtomicU64`/`AtomicI64` do not exist as types on this target, so any crate naming
  one fails to compile. Rust will not silently substitute a lock, because that
  breaks the signal-safety guarantees the type implies.

**protobuf is the C++ casualty, and its failure is a latent bug rather than a real
impossibility.** `CMakeLists.txt` probes correctly:

```cmake
check_cxx_source_compiles("
  #include <atomic>
  int main() { return static_cast<int>(std::atomic<int64_t>{}); }
" protobuf_HAVE_BUILTIN_ATOMICS)
if (NOT protobuf_HAVE_BUILTIN_ATOMICS)
  set(protobuf_LINK_LIBATOMIC true)
endif ()
```

The probe fails on armv5te (it needs `__atomic_load_8` and does not link
`-latomic`), so `protobuf_LINK_LIBATOMIC` is set - the right conclusion. But
`cmake/protobuf-configure-target.cmake` then does:

```cmake
function(protobuf_configure_target target)
    if(protobuf_LINK_LIBATOMIC)
        target_link_libraries(libprotobuf PRIVATE atomic)   # hardcoded, not ${target}
    endif()
```

The first caller is `libprotobuf-lite.cmake:28`, when only `libprotobuf-lite`
exists, so CMake dies with `Cannot specify link libraries for target "libprotobuf"
which is not built by this project`. That branch is dead code on x86-64, aarch64
and armv7, which all pass the probe - nobody has walked into it.

It reached the closure through one thin path:

```
networking module -> environment.corePackages -> pkgs.host -> bind
  -> hardcoded "--enable-dnstap" -> protobufc -> protobuf
```

An overlay dropping `--enable-dnstap` (DNS query logging; nothing here wants it)
removes protobuf *and* abseil-cpp while keeping `host`/`dig` working. Cheaper than
carrying a protobuf patch.

### 11.3 sched_ext cannot link on a uniprocessor kernel — [CONFIRMED]

```
ld.bfd: kernel/sched/build_policy.o: in function `scx_ops_enable_workfn':
  kernel/sched/ext.c:5286: undefined reference to `stop_sched_class'
```

`kernel/sched/build_policy.c` compiles `stop_task.c` only under `#ifdef CONFIG_SMP`,
but `kernel/sched/ext.c` references `stop_sched_class` unconditionally. nixpkgs
enables sched_ext for anything with an eBPF JIT:

```nix
SCHED_CLASS_EXT = whenAtLeast "6.12" (whenPlatformHasEBPFJit yes);
```

and armv5tel qualifies. The 88F6281 is single-core, so `CONFIG_SMP=n` is correct and
sched_ext is what has to go: `SCHED_CLASS_EXT = lib.mkForce no`. This is an
untested-config-combination bug, not an atomics problem - the same recurring theme
that this board sits in a corner of the configuration space nothing else exercises.

### 11.4 The shipped DTB directory is FLAT — [CONFIRMED]

`hardware.deviceTree.name = "marvell/kirkwood-ds409.dtb"` **is wrong**, even though
the kernel source really does keep it in `arch/arm/boot/dts/marvell/`. Read back out
of the built image with `debugfs`, the directory NixOS ships in `/boot/nixos/...-dtbs`
has **225 `.dtb` files, no subdirectories at all**, with `kirkwood-ds409.dtb` at the
top level. The correct value is `hardware.deviceTree.name = "kirkwood-ds409.dtb"`.

Worth flagging because **nothing catches this at build time**: the vendor prefix is
accepted silently and only surfaces as U-Boot failing to load the FDT at boot. It
should be re-checked against a built image after any kernel version bump.

### 11.5 `autoModules`, and a path-scoped alternative

nixpkgs' `autoModules` defaults to true, which in
`pkgs/os-specific/linux/kernel/generate-config.pl` means:

```perl
# Build everything as a module if possible.
$answer = "m" if $autoModules && $alts =~ ... && !($preferBuiltin && $alts =~ /Y/);
```

i.e. answer "m" to every kconfig question with no explicit answer. Measured on this
build:

| | |
|---|---|
| modules **built** | **6,083** (106 MB) |
| modules in the initrd (`modules-shrunk`) | **25** (704 KB) |

and the full 106 MB tree **does** ship in the image, which is most of why the image
is 784 MiB. That is why a headless ARMv5 NAS compiles DRM drivers and IIO pressure
sensors.

`autoModules = false` is the other extreme: only the defconfig plus our explicit
list, and an unforeseen USB dongle means a kernel rebuild.

`nixos/gen-driver-modules.py` implements the middle ground. kconfig symbols are not
path-qualified, but the Kconfig *files* declaring them are, so "every driver under
`drivers/usb`" is a well-defined set. It walks those files, keeps only `tristate`
symbols (a `bool` can never be `m`), and emits `nixos/driver-modules.nix`:

| scope | tristate symbols |
|---|---|
| whole tree (what `autoModules=true` reaches for) | 11,122 |
| `drivers/gpu` | 290 |
| `drivers/iio` | 577 |
| `drivers/net` incl. wireless | 923 |
| **scoped set** (`drivers/usb`, `drivers/net/usb`, `drivers/hid`) | **397** |

Each symbol becomes `lib.kernel.option lib.kernel.module` - the `NAME? m` form
`generate-config.pl` treats as optional - so the many symbols belonging to other
SoCs (`AB8500_USB`, `AM335X_CONTROL_USB`) are skipped on unmet dependencies instead
of failing the build. Without `option` the approach does not work at all.

Wired into `configuration.nix` behind `useScopedDriverModules`, **off by default**
until the stock-settings image is confirmed to boot. Turning it on at the same time
as everything else would only add a suspect. Verified that with the switch off the
image derivation hash is unchanged.

### 11.6 Image contents — [CONFIRMED] built, [VERIFY] boots

`nix-build /src/nixos -A image` produces **821,719,040 bytes (784 MiB)**,
sha256 `a33b439b7f8149905f78882e2477ab31483af52137643768a9365a8370d78f9c`.
DOS label, two partitions:

| part | | |
|---|---|---|
| 1 | 30 MB FAT32 | empty - our bootloader is in SPI flash, not on the stick |
| 2 | 745.7 MB ext4, bootable | root, with `/boot` inside it |

No separate boot partition is needed because U-Boot's bootstd tries `/` **and**
`/boot/` on every partition (§10.14 / `boot/bootstd-uclass.c`
`default_prefixes[]`).

Verified by reading the image back with `debugfs` - every path in
`/boot/extlinux/extlinux.conf` resolves:

| entry | size | |
|---|---|---|
| `LINUX` | 11,386,856 | zImage 6.12.104 |
| `INITRD` | 22,262,720 | initrd |
| `FDT` | 27,327 | `kirkwood-ds409.dtb` |

`APPEND` carries `console=ttyS0,115200n8` and `init=...`, matching the serial setup.

**It has never been booted.** Everything above is static verification of the built
artifact. M5's "boots to a login prompt" and the 118 MB headroom measurement remain
open.


---

## 12. U-Boot fixes needed for the DS410j (beyond ds109_defconfig)

Everything here is [CONFIRMED] on the bench. All of it lives in
`uboot/default.nix` as `substituteInPlace` patches with the reasoning inline.

### 12.1 USB: two separate bugs, neither of them a timeout

The DS410j's rear ports hang off an internal Genesys Logic GL850G hub
(`05e3:0608`), so every stick is behind a hub. Linux enumerates it instantly;
U-Boot did not see it at all.

**Bug 1 - no settle before port reset.** `usb_hub_port_connect_change()` goes
straight from noticing a connect to `usb_hub_port_reset()`, but USB 2.0 §7.1.7.3
(TATTDB) requires >= 100 ms first. Without it the reset lands before the
high-speed chirp settles and the following control transfer fails:

```
unable to get device descriptor (error=-1)
```

Fixed with `mdelay(200)` before the reset.

**Bug 2 - a latched connection-change is treated as a device.** This is the one
that made cold boot fail. `usb_scan_port()` keeps waiting only when *neither* bit
is set:

```c
if (!(portchange & USB_PORT_STAT_C_CONNECTION) &&
    !(portstatus & USB_PORT_STAT_CONNECTION)) { /* keep waiting */ }
```

A VBUS ramp produces a latched `C_CONNECTION` with `CONNECTION` still clear.
Captured from the board:

```
PowerOn : port 1 returns 0
devnum=2 poweron: query_delay=100 connect_timeout=5100
Port 1 Status 100 Change 1        <- C_CONNECTION latched, CONNECTION clear
devnum=2 port=1: USB dev found
usb_disconnect(&hub->children[port]);
```

so it falls through, is acted on as a device, rejected as a disconnect
(`-ENOTCONN`), and **the port is removed from the scan list permanently**.
Nothing rescans it. A healthy port reads `0x101`; the failing one reads `0x100` -
one bit.

Fixed by requiring the `CONNECTION` bit. This keeps upstream's documented special
case ("hub reports no connection change but a device is connected, CCS set but
CSC not") working, because that case has `CONNECTION` set.

**Two dead ends worth recording so nobody repeats them:**

- Raising `CONFIG_USB_HUB_DEBOUNCE_TIMEOUT` (tried 5000) changed nothing - the
  port was dropped before any debouncing could occur. It is back at a modest
  value and is only meaningful *now* that bug 2 is fixed.
- A DEBUG build "worked" throughout, which made this look like a flaky race. It
  was not: `debug()` printfs at 115200 baud simply supplied the missing delays.
  **Never conclude a timing fix works from a DEBUG build.**

**And a testing trap:** chainloading a new U-Boot with `go` from a running U-Boot
inherits a controller whose hub ports are *already powered*, so it never
exercises the VBUS ramp and always succeeds. A fix validated that way is not
validated at all. Only a real power cycle tests this.

### 12.2 The fan: our U-Boot switched it off — [CONFIRMED]

**Safety issue, not polish.** Observed directly: fans spin at the stock
`Marvell>>` prompt and stop the moment our U-Boot takes over.

The DS410j fan is a 3-bit GPIO speed select on **GPIO0 pins 15/16/17**
(`kirkwood-synology.dtsi`, `gpio-fan-150-15-18`), where **0 means off** and the
speed map runs 1=2200 .. 7=4200 rpm. The ds109 board file's MPP table
reconfigures MPP15/16/17 as GPIO - the DS109's own fan is on 32-35, the other DTS
node - and leaves them low.

**Linux does not recover it.** `kirkwood-ds409.dts` sets the node `status = "okay"`,
but the driver fails to probe (`setup of GPIO alarm failed: -524`, §10.3), so the
pins keep whatever U-Boot left. M3 never saw this because that kernel was booted
straight from the stock loader.

Fixed in `board_init()` by driving the pins to a safe speed (3 = 3300 rpm,
`DS410J_FAN_SPEED`). Data is written before the output enable so the pins never
glitch through 0. Note the encoding is not monotonic - 4 is 3000 rpm, *below*
3's 3300.

The `kw_gpio_*` helpers are declared in `mach/gpio.h` but **have no implementation
anywhere in U-Boot 2026.07** (the DM gpio driver replaced them, and
`CONFIG_DM_GPIO` is off here), so the registers are driven directly via
`GPIO_OUT()` / `GPIO_IO_CONF()`. On Kirkwood a **0** bit in `GPIO_IO_CONF`
*enables* the output.

### 12.3 extlinux needs load addresses and raw-initrd support

`ds109_defconfig` predates distro boot, so the extlinux bootmeth fails with
`missing environment variable: kernel_addr_r`. `kernel_addr_r`, `fdt_addr_r`,
`ramdisk_addr_r`, `scriptaddr`, `pxefile_addr_r` and `bootm_size` are now baked
into the built-in default environment.

**Caveat that cost real time:** a *saved* env in mtd4 with a valid CRC completely
replaces the built-in defaults, so these stay missing until mtd4 is rewritten too.

NixOS's initrd is a raw gzipped cpio, not a uImage-wrapped ramdisk, so
`CONFIG_SUPPORT_RAW_INITRD=y` is required or the kernel loads and then:

```
Wrong Ramdisk Image Format
Ramdisk image is corrupt or invalid
```


---

## 13. First NixOS boot on the hardware — [CONFIRMED]

**2026-09-03.** stock U-Boot 1.1.4 -> our U-Boot 2026.07 -> USB extlinux -> NixOS
26.11, to a serial login prompt. Kernel 6.12.104, armv5tel.

### 13.1 The memory work, measured

The first attempt died in `unpack_to_rootfs` with `System is deadlocked on
memory`. Three independent causes, all fixed (§11.5 and `nixos/configuration.nix`):

| | before | after |
|---|---|---|
| `Memory: available` | 57,344K | **87,540K** |
| `cma-reserved` | 16,384K | **0** (`cma=0`) |
| reserved | 55,088K | 41,168K |
| initrd, uncompressed | 56.7 MB | **20.4 MB** (no systemd in initrd) |
| modules built | 6,083 / 106 MB | **445 / 7.9 MB** |
| image | 784 MiB | 652 MiB |

`Freeing initrd memory: 7744K` - it unpacks and is released, where before the
peak (compressed image + tmpfs) exceeded free RAM.

Userspace after boot:

```
               total        used        free      shared  buff/cache   available
Mem:              96          39           3           0          59          57
Swap:             47           3          44
```

57 MB available on a 128 MB board, with zram carrying 47 MB of swap.

### 13.2 Bay -> port mapping confirmed for bays 2 and 4

M3 established 1:1 for bays 1 and 3. With the drives moved to **bays 2 and 4**
they came up as `ata2` and `ata4`, and `ata3: SATA link down` for the empty bay -
so the mapping is 1:1 across all four. `sdb`/`sdc`, both TOSHIBA DT01ACA300 3 TB
at 3.0 Gbps. Note `ata4` needed a retry (`link is slow to respond, please be
patient` / `SRST failed (errno=-16)`) before coming up - slow spin-up, recovered
on its own.

`sdImage.expandOnBoot` worked: `EXT4-fs (sda2): resized filesystem to 1956352`,
root now 7.4 G, 8% used.

### 13.3 The firewall gap — FIXED

**Resolved.** `systemctl is-system-running` now reports **`running`** with **0
failed units**, and the `nixos-fw` chain is installed:

```
Chain INPUT (policy ACCEPT)
target     prot opt source               destination
nixos-fw   all  --  0.0.0.0/0            0.0.0.0/0
```

Cost: kernel code grew 14336K -> 15360K, and available memory went 87540K ->
86500K (54 MB free to userspace rather than 57 MB). Worth it for a working
firewall.

**The fix needed two parts, and the second one is the interesting one:**

1. `NF_TABLES`, `NF_CONNTRACK` built **in** (not modules), plus the netfilter
   subtrees added to the scoped module list (`net/netfilter`,
   `net/ipv4/netfilter`, `net/ipv6/netfilter` - 635 tristate symbols now, up from
   397).
2. **`NFT_COMPAT` must be `module`, not `yes`.** It depends on
   `NETFILTER_XTABLES`, which common-config leaves as `m`, so kconfig offers only
   `N/m`. Answering `y` makes it ask the same question again and
   `generate-config.pl` dies with `repeated question ... line 94`, followed by a
   wall of `Error in reading or end of file.` - the wall is the symptom, the
   repeated question is the cause.

**The original diagnosis, kept because the pattern recurs:**

`systemctl is-system-running` reports **degraded**, one failed unit:

```
firewall.service: iptables: Failed to initialize nft: Protocol not supported
```

Cause: with `autoModules = false` nothing under `net/netfilter` is built, and the
scoped list in `nixos/driver-modules.nix` only covers `drivers/usb`,
`drivers/net/usb` and `drivers/hid`. Networking itself is fine; only the firewall
fails.

Two ways to fix, neither done yet:

1. Add `net/netfilter` and `net/ipv4/netfilter` to `INCLUDE` in
   `gen-driver-modules.py` and regenerate - the case the path-scoped tooling was
   built for.
2. Enable the handful of `NF_TABLES` symbols explicitly in
   `structuredExtraConfig`, which is more precise and keeps the module count down.

This is the expected cost of turning `autoModules` off: it converts silent
over-inclusion into loud, specific failures. Each one needs an explicit decision.


---

## 14. Third flash write: U-Boot v8 and the distro environment — [CONFIRMED]

**2026-09-03.** mtd1 rewritten with the U-Boot carrying all three §12 fixes, and
mtd4 rewritten with the environment extlinux needs. Both in a single unlock
window (§10.10 - unlocking necessarily exposes mtd0, so the fewer windows the
better).

Rehearsed first, on a genuine cold boot: `uImage-ub-v8` TFTP'd and `bootm`'d from
the stock loader found the stick on the **first** `usb start` with no retry and
reached extlinux. Only then was anything written.

```
sf protect unlock 0 0x400000
sf erase 0x80000 0x200000            -> SF: 2097152 bytes @ 0x80000 Erased: OK
sf write 0x03000000 0x80000 0x609C8  -> SF: 395720 bytes @ 0x80000 Written: OK
setenv kernel_addr_r / fdt_addr_r / ramdisk_addr_r / scriptaddr /
       pxefile_addr_r / bootm_size / bootcmd / bootdelay ; saveenv
sf protect lock 0 0x400000
```

| Region | crc32 | |
|---|---|---|
| mtd0 `0x000000` +`0x080000` | `273ca0c6` | unchanged - stage 1 |
| mtd1 `0x080000` +`0x200000` | **`5b703dd6`** | new - U-Boot v8 (payload `ea49d2c0`) |
| mtd2 `0x280000` +`0x140000` | `5fd81497` | unchanged - ramdisk stub |
| mtd3 `0x3C0000` +`0x010000` | `cab00674` | unchanged - vendor MAC/serial |
| mtd4 `0x3D0000` +`0x020000` | **`06ed043d`** | new - env with the distro addresses |
| mtd5 `0x3F0000` +`0x010000` | `368b19d9` | unchanged |
| whole 4 MB chip | **`4b513de1`** | new baseline (was `605f1a9b`) |

Protection restored and proven: a deliberate test erase returned
`ERROR: flash area is locked`.

**Why mtd4 had to be rewritten too.** A saved environment with a valid CRC
*replaces* the built-in defaults wholesale, so the addresses baked into the image
(§12.3) stayed invisible and every boot died with `missing environment variable:
kernel_addr_r`. Writing the payload without the env would have achieved nothing.

### 14.2 First fully unattended cold boot to NixOS — [CONFIRMED]

**M6's goal.** Power on, nothing typed, nothing attached but the USB stick:

```
Hit any key to stop autoboot:  3  2  1  0      <- stock loader, uninterrupted
Hit any key to stop autoboot: 3 2 1 0          <- our U-Boot, uninterrupted
scanning usb for storage devices... 1 Storage Device(s) found   <- first pass, cold
** Booting bootflow 'usb_mass_storage.lun0.bootdev.part_2' with extlinux
Starting kernel ...
Memory: 87540K/131072K available
Freeing initrd memory: 7744K
Welcome to NixOS 26.11 (Zokor)!
ds410j login:
```

Both `Hit any key` countdowns run to zero untouched - that is the whole point.
The USB stick is found on the **first** `usb start`, with no retry, which is what
the §12.1 port-connect fix bought.

Reachable on the network as well: it took `192.168.50.138` from the bench dnsmasq
pool, ping 3/3 with 0% loss, and `sshd` answers `SSH-2.0-OpenSSH_10.5`.

The full chain, all four stages:

```
stock Marvell U-Boot 1.1.4 (mtd0)
  -> our U-Boot 2026.07 (mtd1)        bootm F8080000 F8280000
    -> USB stick, extlinux            bootcmd = "usb start; bootflow scan"
      -> NixOS 26.11, kernel 6.12.104, serial login + ssh
```

### 14.1 Warm reboot: hangs, but the shutdown completes — [CONFIRMED]

§10.6 says warm reboot does not work, which is true, but the detail matters for
operators. `systemctl reboot` on the real NixOS system:

```
shutdown[1]: All filesystems, swaps, loop devices, MD devices and DM devices detached.
shutdown[1]: Syncing filesystems and block devices.
sd 4:0:0:0: [sdc] Synchronizing SCSI cache
sd 2:0:0:0: [sdb] Synchronizing SCSI cache
shutdown[1]: Rebooting.
reboot: Restarting system      <- board hangs here
```

systemd completes the **entire** shutdown - unmounts, swaps off, SCSI caches
flushed - and only the final SoC reset fails. So
"`systemctl reboot`, wait for `Restarting system`, then power cycle" is a **safe**
procedure with no risk to the filesystems. `poweroff` is still untested (M4).


---

## 9. Scope warning

This is **two ports stacked**: a DTS/board port and a bootloader port. Both are
tractable; neither is free.

**RedBoot alone can reach a booting NixOS** (M3 → M5, with `boot.initrd.enable = false`).
U-Boot is what makes the result *pleasant to live with* — real generations, real
rollback, no flash budget. Treat it as the thing that finishes the port, not as a
prerequisite for proving it works.

If M3 fails, stop and reassess rather than working around it. Everything downstream
assumes a mainline kernel that talks to this hardware.

---

## 10. First bring-up: findings and corrections

Everything here is [CONFIRMED] from the running board unless marked otherwise.

### 10.1 The bootloader is not RedBoot

**The board runs `U-Boot 1.1.4 (Mar 17 2010 - 19:27:44) Marvell version: 3.4.4`.**
This document previously asserted eCos RedBoot as [CONFIRMED], and a lot of §2, §5 and
§7 was built on it.

The likely origin of the error is worth recording so it is not repeated: the MTD
partitions really are *labelled* `RedBoot`, `RedBoot config` and `FIS directory`, and
`/proc/mtd` under DSM shows exactly that. But those are inherited Synology labels with
nothing behind them — mainline's own `kirkwood-synology.dtsi` hardcodes the same six
labels. Reading a partition *name* as evidence of the software in it was the mistake.

Boot banner facts: U-Boot occupies `0x00600000`-`0x0068B3B4` and reserves the low 8 MB;
SoC `88F6281 A1 (DDR2)`; CPU 800 MHz, L2 400 MHz, SysClock 400 MHz, TClock 200 MHz;
DRAM 128 MB 16-bit; `Synology Model: DS410j`; `Fan Status: Good`;
`Net: egiga0 [PRIME], egiga1`.

### 10.2 Consequences for the plan

- §5's chainload architecture **survives**, with "RedBoot" replaced by "stock U-Boot".
  It is also now *mandatory* rather than a nicety, because there is no `saveenv`.
- No `fis` commands, no FIS re-carve, no `fconfig`. §2's re-carving plan needs rewriting
  in terms of plain flash offsets; the offsets themselves are unchanged and correct.
- The dangerous command on this box is **`bubt`**, not `fis init`.

### 10.3 Defects worth fixing in a `kirkwood-ds410j.dts`

Booting does not need a custom DTS, but these three do:

1. **`eth1` vs native-SATA pin conflict.** `kirkwood-synology.dtsi` enables the SoC's
   native `sata@80000` with `nr-ports = <2>`, but §1 confirms those ports are
   unpopulated here. It claims MPP20, which `eth1` also wants:
   `pin PIN20 already requested by f1080000.sata; cannot claim for
   f1076000.ethernet-controller` -> `mv643xx_eth: Error applying setting`.
   Disabling `sata@80000` frees the pin. Related: `ds409.dts` enables `&eth1`, but
   `ethphy1` at MDIO address 9 is **missing** on this board and the wired port is
   `eth0` — so enabling `eth1` looks simply wrong for the DS410j.
2. **`local-mac-address`** — without it `eth0` comes up as `00:00:5f:ff:00:00`.
   The real MAC is `00:11:32:02:f9:a6` (§7.2).
3. **`gpio-fan-150-15-18` fails to probe** (`setup of GPIO alarm failed: -524`).
   ~~Not urgent — the fans run from hardware default.~~ **That was wrong, and it
   matters: see §12.2.** It is true only when the kernel is booted straight from
   the *stock* loader, which is how M3 was tested. On the chainloaded path - the
   only path we ship - our U-Boot stops the fans before Linux ever starts, and
   because this driver fails to probe, Linux never turns them back on. Fixed in
   U-Boot for now; fixing the probe here is still wanted so the fan can actually
   be *controlled* rather than pinned.

4. **`reset_phy()` never runs** in our chainloaded U-Boot (§10.14):
   `board/Synology/ds109/ds109.c` hardcodes `char *name = "egiga0"`, which no longer
   matches the DM device name `ethernet-controller@72000`, so `miiphy_set_current_dev`
   fails and the MV88E1116 RGMII delay setup is skipped. Prints
   `No such device: egiga0` on every boot. Ethernet works regardless. This is a
   *U-Boot board-file* defect rather than a Linux DTS one, but it belongs in the same
   DS410j port.

Cosmetic: the SPI flash node says `st,m25p80` but the chip is an M25P32
(`spi-nor spi0.0: found m25p32, expected m25p80`). Harmless; `jedec,spi-nor` probes it.

### 10.5 `bootm` resets on a bad ramdisk argument — [CONFIRMED]

The stock `bootcmd` is `bootm F8080000 F8280000`, i.e. **two** arguments, and it cannot
be changed (no `saveenv`, §5). Tested in RAM with deliberate garbage at the ramdisk
address:

```
mw 0x05000000 deadbeef 10
bootm 0x04000000 0x05000000
  ## Loading Ramdisk Image at 05000000 ...
  Bad Magic Number
  Bad Header C
  <U-Boot banner - the board resets>
```

U-Boot 1.1.4 calls `do_reset()` on a bad ramdisk header. **Unattended boot therefore
requires a valid uImage at flash offset 0x280000, or the box boot-loops.**

This constrains §2's re-carve more than §2 currently states:

- A kernel written at 0x80000 must end before 0x280000, i.e. fit in **2 MB** - the
  §2 target layout's 2.4 MB `kernel-fallback` at 0x190000 is *not* reachable by the
  stock `bootcmd` at all, and the measured 2.91 MiB kernel (§8 M3) exceeds 2 MB anyway.
- ~~**Preferred escape:** an `IH_TYPE_STANDALONE` image at 0x80000.~~ **Superseded by
  §10.8 — standalone is a dead end here.** The surviving idea is right and unchanged:
  put a *loader* (a newer U-Boot, which then has `saveenv` and full freedom) at 0x80000,
  writing **mtd1 only** - mtd0 stays pristine, and a bad write is recoverable because
  the stock loader still TFTP-boots. Only the image *type* changes: **`IH_TYPE_KERNEL`**,
  which leaves `ih_load` alone and satisfies the ramdisk argument from the untouched
  stock `rd.gz` already in mtd2.

  **[CONFIRMED] by test, but the test was misread — see §10.8.** An
  `IH_TYPE_STANDALONE` uImage was TFTP'd and run as `bootm 0x04000000 0x05000000`
  with `deadbeef` planted at the ramdisk address. Output:

  ```
  Image Type:   ARM Linux Standalone Program (uncompressed)
  Verifying Checksum ... OK
  OK
  <jumps straight to the payload>
  ```

  No `Loading Ramdisk Image`, no `Bad Magic Number`, no reset. **That part stands:**
  standalone images are dispatched before any ramdisk processing and the second
  argument is never examined *as a ramdisk*.

  **But it is examined.** The payload then died with `undefined instruction` at
  `pc 02000010`, which was originally attributed to a cache-coherency problem at
  handoff. That diagnosis was wrong; §10.8 has the real cause, read out of the
  U-Boot 1.1.4 source. **`IH_TYPE_STANDALONE` is *not* a usable hook here** — the
  second argument silently overwrites the standalone image's load address.
- **Last resort:** patch the default env inside mtd0. `bootcmd=bootm F8080000 F8280000`
  is at offset **0x71582**, exactly one occurrence, 30 bytes. A length-preserving edit
  to `bootcmd=bootm F8080000\0` + filler drops the second argument without shifting
  layout or needing a CRC (the built-in default env is not CRC-checked; only a stored
  env is). This writes mtd0 and is recoverable only via an external SPI programmer.

### 10.8 The unattended-boot hook is `IH_TYPE_KERNEL`, not `IH_TYPE_STANDALONE` — [CONFIRMED]

Read out of the real `u-boot-1.1.4/common/cmd_bootm.c` (fetched from
`ftp.denx.de`), not recalled. `do_bootm()` dispatches on image type **twice**, and
the first switch contains this:

```c
	switch (hdr->ih_type) {
	case IH_TYPE_STANDALONE:
		name = "Standalone Application";
		/* A second argument overwrites the load address */
		if (argc > 2) {
			hdr->ih_load = htonl(simple_strtoul(argv[2], NULL, 16));
		}
		break;
	case IH_TYPE_KERNEL:
		name = "Kernel Image";
		break;
```

So for a **standalone** image `bootm F8080000 F8280000` sets `ih_load = 0xF8280000`.
The uncompressed path then does `memmove((void *)ntohl(hdr->ih_load), data, len)` —
i.e. it would blast the payload **into the SPI NOR read window** — and the later
jump uses `ih_ep`, which is *not* rewritten. The payload therefore never arrives
where it is entered from.

This explains the §10.5 failure exactly, with no cache theory needed: the 8-byte
toy payload was copied to `0x05000000` and then entered at `ih_ep = 0x02000000`,
which on a freshly powered board is uninitialised DRAM. Hence `undefined
instruction` a few words in. The register dump agrees — `r5 : 04000040` is the
image *data* pointer and `r3 : 02000000` is the untouched entry point.

**`IH_TYPE_KERNEL` does not have this behaviour**, and it is the better hook anyway:

| | standalone | kernel |
|---|---|---|
| `ih_load` clobbered by arg 2 | **yes** | no |
| ramdisk arg | ignored | **must be a valid ramdisk uImage** |
| cache state at handoff | inherited from stock loader | `cleanup_before_linux()` runs first |

The ramdisk requirement is already satisfied **for free, with no extra flash write**:
`flash-backup/mtd2.bin` (the `rd.gz` slot at 0x280000 -> window `0xF8280000`) parses
as a valid `LINUX/ARM/RAMDISK/gzip` uImage, `synology_88f6281_410j 5967`, 994,615
bytes, **header CRC and data CRC both OK** [CONFIRMED, checked offline against the
backup]. And `lib_arm/armlinux.c` **does not copy the ramdisk anywhere** — the
`memmove` to `ih_load` there is guarded by `CONFIG_B2 || CONFIG_EVB4510 ||
CONFIG_ARMADILLO`, none of which apply to Kirkwood. It only validates the header,
CRCs the data, checks `IH_OS_LINUX`/`IH_CPU_ARM`/`IH_TYPE_RAMDISK`, and records
`initrd_start`/`initrd_end` for an ATAG. **No DRAM outside our load address is
touched.**

**New constraint this creates:** Synology's `rd.gz` in **mtd2 is now load-bearing for
our own boot chain**, and since DSM is expendable that is the *only* reason it matters.
Something at `0xF8280000` must parse as a valid `LINUX/ARM/RAMDISK` uImage with good
header and data CRCs, or `bootm` hits `Bad Magic Number` / `Bad Data CRC` and
`do_reset()`s (§10.5) — a boot loop.

It does **not** have to be Synology's. A 64-byte header plus a few bytes of data is
enough, which would reclaim nearly all of mtd2's 1.25 MB. Two rules for whoever does
that: build and CRC the stub offline, and **rehearse it with `bootm <ram> <ram-stub>`
before writing**, because a blank mtd2 is the one failure mode in this chain that
boot-loops rather than dropping to a prompt.

So the payload to write into the `zImage` slot is:

```
mkimage -A arm -O linux -T kernel -C none \
        -a 0x02000000 -e 0x02000000 \
        -n 'U-Boot 2026.07 DS410j chainload' -d u-boot.bin uImage-ub-kernel
```

395,488 bytes (64-byte header + 395,424) against the 2 MB slot. Built and staged as
`uboot/out/uImage-ub-kernel`; the padded 2 MB slot image is
`uboot/out/mtd1-uboot-chainload.bin` (crc32 `115d3d96`). **Nothing flashed yet.**

`ih_load = ih_ep = 0x02000000` keeps the *same* `CONFIG_TEXT_BASE` that §10.7
already proved via `go`, which is what makes this rehearsable: running
`bootm 0x04000000 0xF8280000` from RAM exercises the identical code path, with the
real flash ramdisk as the second argument. The only difference from the flashed case
is where argument 1 points.

**Rehearsed on hardware and PASSED — [CONFIRMED]**, zero flash writes:

```
bootm 0x04000000 0xF8280000
  ## Booting image at 04000000 ...
     Image Name:   U-Boot 2026.07 DS410j chainload
     Image Type:   ARM Linux Kernel Image (uncompressed)
     Load Address: 02000000     Entry Point:  02000000
     Verifying Checksum ... OK
  OK
  ## Loading Ramdisk Image at f8280000 ...
     Image Name:   synology_88f6281_410j 5967
     Image Type:   ARM Linux RAMDisk Image (gzip compressed)
     Verifying Checksum ... OK
  Starting kernel ...
  <debug_uart>
  U-Boot 2026.07 ... SoC: Kirkwood 88F6281_A1 ... DRAM: 128 MiB
  Loading Environment from SPIFlash... SF: Detected m25p32 ... total 4 MiB
  *** Warning - bad CRC, using default environment
  => (prompt)
```

Both the `SKIP_LOWLEVEL_INIT_ONLY` binary (§10.9) and the `IH_TYPE_KERNEL` wrapper
are therefore proven on the real entry path. Flash verified `8bc4bbb7` **twice** -
before, from the stock loader over the mapped window (`crc32 0xf8000000 0x400000`),
and after, from U-Boot 2026.07 over SPI (`sf read 0x03000000 0 0x400000` then
`crc32`). Nothing was written.

**Risk note for the mtd1 write, from the same source read:** a corrupt or blank mtd1
does **not** boot-loop. In `do_bootm()` the *main* image's `Bad Magic Number`,
`Bad Header Checksum` and `Bad Data CRC` all `return 1` to the shell - only the
*ramdisk* failures call `do_reset()` (§10.5). So a bad mtd1 write drops to the stock
`Marvell>>` prompt, which still TFTP-boots. Recovery is `flash-backup/mtd1.bin` over
the network. This makes the mtd1 write materially safer than §10.5 assumed.

After the handoff the ds109 default env runs its stock `bootcmd` (`ping 192.168.1.2`,
then a USB scan) and fails through to the `=>` prompt, because mtd4 still holds
zeros. Two cosmetic consequences to fix when the env is written: the default env sets
`ethact egiga0`, which modern U-Boot does not have (`No such device: egiga0`; the
device is `ethernet-controller@72000`), and `Model:` reads `Synology DS109, DS110,
DS110jv20` from the ds109 DTB.

### 10.11 First flash write: mtd1 now holds our U-Boot — [CONFIRMED]

**2026-09-03. The first irreversible write. `flash-backup/` is no longer a
byte-for-byte description of the device.**

Done from the chainloaded U-Boot 2026.07 over `sf`, with the payload TFTP'd to
`0x03000000` and CRC-checked in RAM first:

```
sf protect unlock 0 0x400000
sf erase 0x80000 0x200000            -> SF: 2097152 bytes @ 0x80000 Erased: OK
sf write 0x03000000 0x80000 0x608E0  -> SF: 395488 bytes @ 0x80000 Written: OK
sf protect lock 0 0x400000
```

Verified by reading back over SPI, every value matching a checksum computed offline
from the backups *before* the write:

| Region | crc32 | |
|---|---|---|
| payload `0x80000` +`0x608E0` | `63a0508d` | matches `uboot/out/uImage-ub-kernel` |
| whole mtd1 slot `0x80000` +`0x200000` | `115d3d96` | matches `uboot/out/mtd1-uboot-chainload.bin` |
| **mtd0** `0x0` +`0x80000` | `273ca0c6` | **unchanged** |
| **mtd2** `0x280000` +`0x140000` | `067e2394` | **unchanged** - still our ramdisk argument |
| whole 4 MB chip | `00471165` | exactly the predicted post-write value |

Because the full-chip crc32 matches a value predicted offline, **the only bytes that
changed anywhere on the chip are the mtd1 slot.**

Protection was restored afterwards and proven effective - a deliberate test erase of
a spare sector returned `ERROR: flash area is locked`, and the chip re-verified at
`00471165` after that test.

**New expected checksums.** `crc32 0xf8000000 0x400000` from the stock loader became
**`00471165`** at this point, not `8bc4bbb7`. (**Superseded by §10.14**, which rewrote
mtd2 and mtd4 as well; the current whole-chip value is `605f1a9b`.) `8bc4bbb7` is the
*pristine stock* value and is what `flash-backup/` and `flash-backup-copy2/` still
hold - they remain the recovery source, unchanged and still verifying clean.

Stock DSM no longer boots. **That is intended and is not a cost the project is paying
back** - see CLAUDE.md, "What we are protecting". Should it ever be wanted anyway:
unlock, erase `0x80000` +`0x200000`, write `flash-backup/mtd1.bin`, re-lock.

### 10.12 Unattended cold boot into our own U-Boot — [CONFIRMED]

**M6's core goal. Observed on the first cold boot after the mtd1 write, with no host
intervention of any kind:**

```
Hit any key to stop autoboot:  3  2  1  0
## Booting image at f8080000 ...
   Image Name:   U-Boot 2026.07 DS410j chainload
   Image Type:   ARM Linux Kernel Image (uncompressed)
   Load Address: 02000000     Entry Point:  02000000
   Verifying Checksum ... OK
OK
## Loading Ramdisk Image at f8280000 ...
   Image Name:   synology_88f6281_410j 5967
   Verifying Checksum ... OK

Starting kernel ...
<debug_uart>
U-Boot 2026.07 ... SoC: Kirkwood 88F6281_A1 ... DRAM: 128 MiB
=>
```

The countdown running to `0` uninterrupted is the whole point: nothing was typed, no
TFTP server was consulted, and the payload came out of **flash at `f8080000`**, not
RAM. Every prediction in §10.8 held on the real path - `ih_load` was respected, the
stock `rd.gz` satisfied the ramdisk argument, and the handoff was clean.

Flash re-verified `00471165` afterwards: booting this way writes nothing.

**What is *not* yet done.** Reaching the `=>` prompt is not yet a useful autoboot. The
env in mtd4 is still zeros, so U-Boot falls back to the ds109 built-in `bootcmd` and
spends ~13 s failing through it before giving up:

```
No such device: egiga0              <- default env sets ethact=egiga0; the DM device
                                       is 'ethernet-controller@72000'
ping failed; host 192.168.1.2 is not alive
scanning usb for storage devices... 0 Storage Device(s) found
Wrong Image Type for bootm command
ERROR -91: can't get kernel image!
```

None of that is a fault - it is the ds109 default env doing exactly what it says. It
goes away when a real env is written to mtd4, which **§10.13 has now unblocked**: the
stock loader has no stored-env read path at all, so an env at `0x3D0000` is invisible
to it and cannot disturb `bootcmd=bootm F8080000 F8280000`.

### 10.13 The stock loader has no stored environment at all — [CONFIRMED]

This was the open [VERIFY] gating the mtd4 env write: if the stock Marvell 1.1.4
loader also read `0x3D0000`, a valid U-Boot env written there would be picked up by
*both* loaders (the on-flash env format - crc32 followed by `key=value\0` data - has
never changed), overriding the stock `bootcmd=bootm F8080000 F8280000` and breaking
the chainload before it starts.

**It does not.** Settled offline against `flash-backup/mtd0.bin` and the real
u-boot-1.1.4 source, with no hardware access and no writes.

The two messages in `common/env_common.c` `env_relocate()` are mutually exclusive at
compile time, which makes the boot banner a direct readout of the build config:

```c
	if (gd->env_valid == 0) {
#if defined(CONFIG_GTH) || defined(CFG_ENV_IS_NOWHERE)  /* Environment not changable */
		puts ("Using default environment\n\n");
#else
		puts ("*** Warning - bad CRC, using default environment\n\n");
#endif
```

The stock loader prints **`Using default environment`** (§10.1 evidence, and every
boot since), i.e. the `CFG_ENV_IS_NOWHERE` branch. Confirmed in the binary - a string
search of `mtd0.bin`:

| String | |
|---|---|
| `Using default environment` | **found** @ `0x340FF` |
| `*** Warning - bad CRC, using default environment` | **absent** |
| `bad CRC` (anywhere) | **absent** |
| `saveenv`, `Saving Environment` | **absent** |
| `Erasing Flash`, `Un-Protected`, `Writing to Flash` | **absent** |

The `#else` branch was never compiled in, and there is no env-writing or flash-writing
code in the image either. The env is built-in only; that is *why* there is no
`saveenv` (§5) rather than it being a separate quirk.

Constant search: `0xF83D0000` does not appear at all. `0x003D0000` appears exactly
once, at `0x70DFE` — which is offset ≡ 2 (mod 4), so it cannot be an ARM 32-bit
constant, and its context confirms it is two adjacent entries of a small lookup table
(`… 27 00 00 00 | 3d 00 00 00 …`) read across the boundary. A coincidence, not a
pointer.

**Consequence: the mtd4 env write is unblocked**, and is the lowest-risk write on the
chip (§7 risk table) - currently zeros, read by nothing today, re-flashable from the
stock prompt via TFTP + Linux. The one caveat previously noted here — that DSM might read mtd4 for its own purposes —
**is moot**: DSM is expendable (CLAUDE.md, "What we are protecting"). mtd4 is zeros
today, so nothing is being displaced, and nothing else on the chip reads it.

### 10.14 mtd2 stub + mtd4 environment, one unlock window — [CONFIRMED]

**2026-09-03, second flash write.** Both remaining writes done inside a *single*
unlock window, because unlocking necessarily exposes mtd0 (§10.10) and the fewer
times that happens the better.

**mtd2: Synology's `rd.gz` replaced by a 685-byte stub.** DSM is expendable
(CLAUDE.md, "What we are protecting"), so mtd2 only ever needed to be *a* valid
ramdisk uImage, not *Synology's*. `uboot/out/stub-ramdisk.uimg` is a 64-byte header
plus 621 bytes of text explaining what it is and why erasing it boot-loops the box.
**Reclaims 1,310,035 bytes** of the 1.25 MB partition.

Rehearsed before writing, which is what made erasing the original safe - the stock
loader was made to accept the stub as its ramdisk argument from RAM first:

```
bootm 0x04000000 0x05000000
  ## Loading Ramdisk Image at 05000000 ...
     Image Name:   DS410j chainload ramdisk stub
     Image Type:   ARM Linux RAMDisk Image (uncompressed)
     Verifying Checksum ... OK
```

The stub was also checked offline against the six tests `lib_arm/armlinux.c` actually
performs, in order: magic, header CRC, data CRC, `ih_os == IH_OS_LINUX`,
`ih_arch == IH_CPU_ARM`, `ih_type == IH_TYPE_RAMDISK`. Nothing else is examined.

**mtd4: environment written via `saveenv`.** Unblocked by §10.13. Final contents:

```
bootcmd=usb start; bootflow scan
bootdelay=3
ethaddr=00:11:32:02:f9:a6
ipaddr=192.168.50.50  serverip=192.168.50.1  netmask=255.255.255.0
```

plus `ethact` cleared and the dead `x_bootcmd_ethernet` / `x_bootcmd_kernel` /
`x_bootargs_root` and stale `bootargs` removed.

**`bootflow scan` takes no flags on this build — [CONFIRMED] the hard way.** The
obvious `bootflow scan -lb` fails with `Flags not supported: enable
CONFIG_BOOTSTD_FULL` followed by a usage dump; it does not boot anything. Bare
`bootflow scan` is the supported form, and with nothing attached it returns instantly
and silently. Caught by trying the command at the prompt *before* baking it into
flash - worth keeping as a habit, since a broken `bootcmd` in flash is only
recoverable through the `bootdelay` window.

`bootdelay=3` is deliberate and **must never be 0**. Every U-Boot 2026.07 we run
reads this env, including one TFTP'd into RAM for rescue, so a nonzero delay is the
only guarantee that a bad `bootcmd` can be interrupted.

**Verification.** All five untouched regions re-read over SPI and matched values
predicted offline *before* the write; protection restored and proven with a test
erase that returned `ERROR: flash area is locked`.

| Region | crc32 | |
|---|---|---|
| mtd0 `0x000000` +`0x080000` | `273ca0c6` | unchanged - stage 1 |
| mtd1 `0x080000` +`0x200000` | `115d3d96` | unchanged - our U-Boot |
| mtd2 `0x280000` +`0x140000` | `5fd81497` | **new** - the stub |
| mtd3 `0x3C0000` +`0x010000` | `cab00674` | unchanged - vendor MAC/serial |
| mtd4 `0x3D0000` +`0x020000` | `6c573a0c` | **new** - saved env |
| mtd5 `0x3F0000` +`0x010000` | `368b19d9` | unchanged |
| whole 4 MB chip | **`605f1a9b`** | new baseline (was `00471165`) |

**Confirmed by unattended cold boot**, no host intervention:

```
Hit any key to stop autoboot:  3  2  1  0
## Booting image at f8080000 ...
   Image Name:   U-Boot 2026.07 DS410j chainload      Verifying Checksum ... OK
## Loading Ramdisk Image at f8280000 ...
   Image Name:   DS410j chainload ramdisk stub        Verifying Checksum ... OK
Starting kernel ...
U-Boot 2026.07 ...
Loading Environment from SPIFlash... OK          <- no "bad CRC": mtd4 is live
Hit any key to stop autoboot: 3 2 1 0
starting USB... 0 Storage Device(s) found
=>
```

`Loading Environment from SPIFlash... OK` with no `*** Warning - bad CRC` is the proof
the env is being read and trusted. The ~13 s of `ping 192.168.1.2` / `fatload`
flailing is gone.

**Still cosmetic: `No such device: egiga0`.** This survives clearing `ethact` because
it does not come from the environment at all - `board/Synology/ds109/ds109.c` has

```c
void reset_phy(void)
{
	char *name = "egiga0";
	if (miiphy_set_current_dev(name))
		return;      /* always taken: the DM device is ethernet-controller@72000 */
```

so `reset_phy()` bails immediately and the MV88E1116 RGMII Tx/Rx delay tweak never
runs. Ethernet works anyway (repeated TFTP at 3.6 MiB/s), so this is not urgent, but
it belongs on the list for a proper DS410j board port alongside §10.3.

### 10.10 The SPI flash is hardware write-protected — [CONFIRMED]

The first real flash write attempt was **rejected by the chip**, not by U-Boot policy:

```
=> sf erase 0x80000 0x200000
ERROR: flash area is locked
```

This is the M25P32's block-protect bits, and the stock loader has been reporting it
all along - `flinfo` says `Write Protection: All` (§10.1 evidence). Nothing was
written; flash re-verified `8bc4bbb7` immediately afterwards. **Any plan that writes
flash must unlock first**, which no previous section accounted for.

`sf protect lock/unlock <sector> <len>` is available in our build
(`CONFIG_SPI_FLASH_LOCK=y`, `CONFIG_SPI_FLASH_STMICRO=y`), so the mechanism exists.

**The awkward part — M25P32 protection is top-anchored.** BP2:0 select an upper
fraction of the array (000 = none, 001 = top 1/64, ... 110 = top 1/2, 111 = all).
There is no bottom-anchored option and no TB bit. mtd0 lives at offset 0, so **there
is no BP setting that leaves mtd0 protected while freeing the `zImage` slot at
0x80000** - any unlock that reaches 0x80000 necessarily unprotects the whole chip,
mtd0 included.

So the write sequence has to be: unlock all -> erase mtd1 -> write mtd1 -> verify ->
**re-lock all**, restoring `Write Protection: All`. The exposure window is real but
bounded, and the BP bits are chip state, not data - they are not in `flash-backup/`
and toggling them cannot alter any partition's contents.

[VERIFY] Whether the chip's SRWD bit is set and tied to a `W#` pin held low. If so
the status-register write is silently ignored and `sf protect unlock` will not take
effect - the erase would simply keep failing, which is a safe failure.

### 10.9 Chainload handoff now runs `cpu_init_crit` — `SKIP_LOWLEVEL_INIT_ONLY`

§10.5's cache worry was the wrong diagnosis for that particular failure, but the
underlying exposure was real and is now closed. `ds109_defconfig` sets
`CONFIG_SKIP_LOWLEVEL_INIT=y`, and in `arch/arm/cpu/arm926ejs/start.S` that skips
**the whole of `cpu_init_crit`** — so the chainloaded U-Boot inherited the stock
loader's cache and MMU state wholesale. The stock env is not shy about that state:
`disL2Cache=no`, `setL2CacheWT=yes`, `enaICPref=yes`, `enaDCPref=yes`.

`CONFIG_SKIP_LOWLEVEL_INIT_ONLY=y` is the right knob for a chainloaded payload: it
still runs `cpu_init_crit` (test-and-clean the D-cache, invalidate TLB and I-cache,
disable MMU and D-cache, re-enable I-cache) and skips only the `bl lowlevel_init`
that would re-do pll/mux/DDR. The two symbols are independent bools in
`arch/Kconfig`, so `uboot/default.nix` clears the one the defconfig sets. Verified
in the built ELF, not just in `.config`:

```
20002fc:  eb000001  bl  2000308 <cpu_init_crit>
2000308:  e3a00000  mov r0, #0
200030c:  ee17ff7a  mrc 15, 0, APSR_nzcv, cr7, cr10, {3}   <- test and clean D-cache
2000310:  1afffffd  bne 200030c
2000314:  ee080f17  mcr 15, 0, r0, cr8, cr7, {0}           <- invalidate TLB
2000318:  ee070f15  mcr 15, 0, r0, cr7, cr5, {0}           <- invalidate I-cache
...
2000338:  e1a0f00e  mov pc, lr                             <- no bl lowlevel_init
```

`cpu_init_crit` touches no stack, so it is safe this early — before
`CUSTOM_SYS_INIT_SP_ADDR` is even loaded. Binary grew 395,392 -> 395,424 bytes. The
previous binary is kept as `uboot/out/u-boot-lowlevelskip-all.bin` and wrapped as
`uImage-ub-kernel-oldcfg` in case the change needs to be bisected on hardware.

On the `IH_TYPE_KERNEL` path this is now belt *and* braces: the stock loader's
`cleanup_before_linux()` already disables caches before entry.

### 10.7 Chainloading a modern U-Boot works — [CONFIRMED]

U-Boot **2026.07** built from `ds109_defconfig` (`pkgsCross.armv5tel-multiplatform.buildUBoot`,
see `uboot/default.nix`) runs on this board, chainloaded from the stock loader with
`go`, **with no flash writes at all**. `u-boot.bin` is **395,376 bytes (386 KB)** against
the 1 MB slot §2 allocates - comfortable.

```
tftpboot 0x02000000 u-boot-ds109.bin
go 0x02000000
  ## Starting application at 0x02000000 ...
  U-Boot 2026.07 ... SoC: Kirkwood 88F6281_A1
  DRAM: 128 MiB
  Loading Environment from SPIFlash... SF: Detected m25p32 ... total 4 MiB
```

**Two build changes were required; ds109_defconfig does not work as shipped here:**

1. `CONFIG_TEXT_BASE` must move off `0x600000` - that is where the *stock* U-Boot is
   running, so TFTPing there clobbers the loader doing the loading. Built at
   `0x02000000`.
2. `CONFIG_CUSTOM_SYS_INIT_SP_ADDR` must move off `0xc8012000`. That is Kirkwood
   internal SRAM, whose window is mapped by `lowlevel_init`/BootROM - and
   `ds109_defconfig` sets `CONFIG_SKIP_LOWLEVEL_INIT=y`. Chainloaded, the window is not
   mapped and U-Boot faults on its first stack push, **before any console exists**:
   total silence at every baud rate. Moved to `0x01f00000` (DRAM). This was the
   predicted §5 "cache/MMU state at handoff" class of failure, though the actual cause
   was the stack, not the caches.

**Always build with `CONFIG_DEBUG_UART`** (NS16550, base `0xf1012000`, shift 2,
clock = TCLK 200 MHz). It prints from the first instructions and is the difference
between a diagnosable hang and a silent one.

What the chainloaded U-Boot can do here:

| Thing | Result |
|---|---|
| SPI NOR | **works** - `SF: Detected m25p32 ... 4 MiB`, so `saveenv` is available |
| USB | **works** - `USB EHCI 1.00, Bus usb@50000: 2 USB Device(s) found` |
| Env | reads from `0x3D0000`, reports `bad CRC, using default environment` |
| Ethernet | **works** once the MAC is baked in - `host 192.168.50.1 is alive` |
| SATA bays | not available, as §5 predicted (PCIe 88SX7042, no U-Boot driver) |

**Env location [CONFIRMED]:** `CONFIG_ENV_OFFSET=0x3D0000` = **mtd4**, the partition
§10.1 found full of zeros. The chainloaded U-Boot reads it and reports a bad CRC.
This makes persisting `bootcmd` an **mtd4** write, not an mtd0 write - far lower risk
than patching the bootloader.

**The stock loader does *not* read `0x3D0000` — [CONFIRMED], see §10.13.** It has no
stored-env read path at all. Writing mtd4 therefore cannot affect the stock loader's
`bootcmd`, and cannot break the chainload.

**Full chain verified end to end, zero flash writes:**

```
stock Marvell U-Boot 1.1.4  --go 0x02000000-->  U-Boot 2026.07
                            --tftpboot + bootm-->  Linux 6.12.104
   ata1: SATA link up 3.0 Gbps -> sda    ata3: SATA link up 3.0 Gbps -> sdb
   Run /init as init process -> busybox serial shell
```

All six MTD partitions were re-checksummed from Linux afterwards and match
`flash-backup/` byte-for-byte, so nothing in this sequence touches flash. **This is the
TFTP-on-every-boot path working today**, minus persistence (which needs the payload in
the `zImage` slot per §10.5, plus `saveenv` to mtd4).

**Ethernet needs `ethaddr` at first probe.** The ds109 default env has no `ethaddr` and
the ds109 DTB no `local-mac-address`, so the eth uclass fails the device with
`No valid MAC address found`. Every retry then re-enters `mvgbe_probe()`, which
`mdio_register()`s a bus named after the device, tripping the duplicate check
(`non unique device name 'ethernet-controller@72000'`). **Setting `ethaddr` from the
U-Boot shell is too late** - the device has already failed. `uboot/default.nix` patches
the real MAC into the built-in default env via `preConfigure` (not `postPatch`, which
would clobber `buildUBoot`'s own `patchShebangs`).

### 10.6 Warm reboot hangs the board — [CONFIRMED]

`reboot -f` under 6.12.104 prints `reboot: Restarting system` and then hangs; only a
power cycle recovers. **U-Boot 2026.07's `reset` fails the same way** (`resetting ...`,
then dead). The *stock* Marvell U-Boot 1.1.4 resets fine - observed twice, via
`do_reset()` on a bad ramdisk header. So the SoC reset path works on this hardware and
it is mainline's Kirkwood reset that does not reach it, in both projects. Suspect the
same board MCU that handles poweroff (§4) also gates reset. See the M4 checklist.

### 10.4 Build artifacts

`kernel/default.nix` builds two variants with `pkgsCross.armv5tel-multiplatform`
(**not** `pkgsCross.sheevaplug`, which no longer exists in nixpkgs; the current
attribute resolves to the same `armv5tel-unknown-linux-gnueabi` triple):

- `-A kernel` — bring-up image: `mvebu_v5_defconfig` + the §4 must-haves, embedded
  static-busybox initramfs, gzip. 7.2 MB. Boots to a serial shell. **Not** a
  flash-budget candidate.
- `-A kernelMin` — flash candidate: no initramfs, `CONFIG_KERNEL_XZ`, Kirkwood only,
  and everything not needed to reach an ext4 root on the PCIe SATA controller removed.

Only the kernel derivation builds locally — the whole armv5tel *cross toolchain*
substitutes from `cache.nixos.org`. §6's "no binary cache for armv5tel" is true for
*target* packages but not for the cross compiler, which is an x86_64 package.
