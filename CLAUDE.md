# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Porting mainline Linux + NixOS onto a Synology DS410j (Marvell Kirkwood 88F6281,
armv5tel, 118 MB usable RAM, **Marvell U-Boot 1.1.4** bootloader, 4 MB SPI NOR flash).

**Status: working.** The box cold-boots unattended to NixOS 26.11 on kernel 6.12.104 -
serial login and ssh, `systemctl is-system-running` reports `running` with zero failed
units. There are nix builds for the kernel (`kernel/`), U-Boot (`uboot/`) and the
cross-compiled NixOS image (`nixos/`), plus bench helper scripts and verified flash
backups. No tests.

Remaining work is in `PORTING.md` §7: fan *control* (it is pinned, not controlled),
a `kirkwood-ds410j.dts`, warm reboot, LEDs, and LUKS on the array.

`PORTING.md` is the source of truth for the plan and for progress. `OPERATIONS.md` is the
bench setup: serial/network topology, the helper scripts in `kernel/`, the gotchas that
have already cost time, and a **flash checklist that must be read before any flash
write**. Build commands live in the `.nix` files, which carry their own reasoning.

**Flash state (`PORTING.md` §2).** The bootloader is **Marvell U-Boot 1.1.4, not
RedBoot** - the `fis`-named partitions are inherited Synology labels with nothing behind
them. **mtd1** holds our `IH_TYPE_KERNEL`-wrapped U-Boot 2026.07 instead of Synology's
kernel, **mtd2** a 685-byte ramdisk stub instead of Synology's `rd.gz` (reclaiming
1.25 MB), and **mtd4** a real U-Boot environment. The box cold-boots unattended, with
nothing attached but a USB stick, all the way to a NixOS login.

**mtd0 is untouched**, write protection is restored, and whole-chip crc32 is now
`4b513de1` (`8bc4bbb7` was pristine stock; per-partition values in `OPERATIONS.md`).
`flash-backup/` still describes the stock chip and is still the recovery source. Stock
DSM no longer boots, which is **fine and intended** - see "What we are protecting".

## What we are protecting

**Stock DSM is expendable. The chainload is not.** The project does not care about
Synology's OS, its kernel in mtd1, or its `rd.gz` in mtd2 as *Synology* artifacts.
What must survive every future change is the **two-stage bootloader chain**, because
that is the entire brick-resistance story:

```
stock Marvell U-Boot 1.1.4 (mtd0, NEVER written)  ->  our U-Boot 2026.07 (mtd1)
```

Stage 1 is the irreplaceable one: it is in mtd0, it TFTP-boots, and it is the only
recovery path short of a SOIC clip. Stage 2 is fully re-flashable *through* stage 1.
So the invariants are:

- **mtd0 stays byte-for-byte pristine.** Never `bubt`. This outranks everything.
- **Keep the chain two-stage.** Do not "simplify" by putting our U-Boot in mtd0 or by
  making the box depend on a single loader. The redundancy is the point.
- Anything that makes the stock loader fail to reach stage 2 unattended is a
  regression, even if the box is still recoverable by hand.
- Restoring DSM is *not* a recovery requirement. The recovery requirement is that the
  stock loader still TFTP-boots, which is true as long as mtd0 is intact.

## Safety rules that override convenience

These come from `PORTING.md` §0 and are non-negotiable. Violating any of them can brick the
device with no software recovery path:

- Never write to `mtd0` — flash offset 0, the only recovery path short of a SOIC clip.
  It is *labelled* "RedBoot" but holds **Marvell U-Boot 1.1.4**. In practice: **never run
  `bubt`**, the vendor's flash-the-bootloader command. That is the one command that bricks
  this box.
- ~~Never run RedBoot's `fis init`~~ — **not applicable**, there is no RedBoot. The
  `fis`-named partitions are inherited Synology labels.
- Back up all six MTD partitions before any flash write (§2). **Already done** and
  verified byte-for-byte: `flash-backup/` and `flash-backup-copy2/`, plus a full-chip
  `ds410j-flash-full-4MB.bin` (crc32 `8bc4bbb7`). That is the *stock* image; the device
  itself now reads `4b513de1` because mtd1, mtd2 and mtd4 were rewritten (§2).
  `OPERATIONS.md` carries the per-partition values.
- **The flash is hardware write-protected** (M25P32 block-protect bits; `flinfo` says
  `Write Protection: All`). `sf erase` fails with `ERROR: flash area is locked` until
  `sf protect unlock` runs. Protection is **top-anchored**, so unlocking far enough to
  reach mtd1 unprotects mtd0 too - always re-lock immediately after verifying a write.
- **mtd2 is load-bearing for our own boot chain** - and *only* for ours now, since DSM
  is expendable. The stock `bootcmd`'s second argument is a real ramdisk argument on
  the `IH_TYPE_KERNEL` path, and Synology's `rd.gz` currently satisfies it. Erasing
  mtd2 boot-loops the box (§4). It may be *replaced* by a minimal valid ramdisk
  uImage - it does not have to stay Synology's - but it must never be merely blank.
- Serial console (3.3 V TTL, 115200 8N1) must be working before the first flash write.
  It is on **`/dev/ttyUSB0`** here (was `/dev/ttyS1`; the device name changes when the
  host<->VM handover changes) — see `OPERATIONS.md`.
- **Our U-Boot switches the fans OFF, and Linux does not turn them back on** (§5.3).
  The fan is a 3-bit GPIO speed select on GPIO0 15/16/17 where 0 = off; the ds109 MPP
  table leaves those pins low, and `gpio-fan-150-15-18` fails to probe under Linux
  (§2), so nothing recovers it. U-Boot now pins a safe speed in `board_init()`.
  **Any U-Boot built without that patch must not be left running with drives fitted.**
  §5.3's old "the fans run from hardware default" is true only for the stock-loader
  path, which is not the path we ship.
- `bootdelay` is 3 s and **cannot be changed persistently** — the stock loader has no
  `saveenv`, so all `setenv` changes are RAM-only. A power cycle always returns to a
  known-good stock configuration.
- A modern U-Boot is chainloaded from the stock U-Boot into the freed `zImage` slot; it
  never replaces the stock loader. Verified working in RAM (`PORTING.md` §5.1).
- **Warm reboot does not work** — neither Linux nor U-Boot 2026.07 can reset this SoC.
  Every reset needs a human to power cycle the box.
- Never run `nix` **evaluation** on the device — 118 MB will OOM the evaluator. All builds
  cross-compile on x86_64 via **`pkgsCross.armv5tel-multiplatform`** (`pkgsCross.sheevaplug`
  no longer exists in nixpkgs; the current name resolves to the same
  `armv5tel-unknown-linux-gnueabi` triple). Closure *copying* to the device may be fine.

## Confidence markers

`PORTING.md` tags factual claims `[CONFIRMED]` (observed on this hardware),
`[LIKELY]` (strong inference), or `[VERIFY]` (must be checked against the actual kernel/U-Boot
tree or hardware). Several `[VERIFY]` items are recollections of trees as of ~May 2026 and may
be stale.

Preserve this convention when editing. Never silently promote a `[VERIFY]` to a bare claim —
promote it only after actually checking, and say what you checked against. An unverified claim
must not become a load-bearing assumption.

## Architecture of the plan

Three constraints shape every decision, and knowing them explains choices that otherwise look
arbitrary:

1. **Flash budget.** 2 MB kernel slot (3.25 MB after re-carving FIS), 1.25 MB initrd slot.
   A NixOS stage-1 initrd is 15–40 MB, so it cannot live in flash — hence `/boot` on USB.
2. **RAM.** 118 MB forces cross-compilation and a minimal closure.
3. ~~**Hand-written DTS.**~~ **Resolved:** mainline's `kirkwood-ds409.dts` already declares
   `synology,ds410j` and boots this board. A custom DTS is now only wanted for three
   defects (`PORTING.md` §7.1), not to boot.

Two boot paths are maintained deliberately, for redundancy:

- **stock U-Boot → kernel directly** (fallback): appended DTB, `boot.initrd.enable = false`, root on
  a plain ext4 partition with PCI + `sata_mv` + ext4 built into the kernel. Sufficient to reach
  a booting NixOS on its own.
- **stock U-Boot → modern U-Boot → USB `/boot`** (preferred, chainload verified in RAM): unlocks
  `boot.loader.generic-extlinux-compatible`, real generations and rollback. U-Boot almost
  certainly cannot see the SATA bays (the 88SX7042 is behind PCIe and has no U-Boot driver),
  which is *why* `/boot` is on USB rather than on the array.

Non-obvious couplings worth holding in mind:

- The SATA controller is a **PCIe** device (88SX7042), not the SoC's native ports. Anything that
  forgets `CONFIG_PCI` + Kirkwood PCIe host support loses all four bays.
- **`CONFIG_KUSER_HELPERS=y` is mandatory.** ARMv5TE lacks LDREX/STREX; without it every glibc
  binary breaks strangely. Some hardening profiles disable it — check NixOS's kernel config.
- **Rust is the main userland blocker.** `armv5te` reports a 32-bit max atomic width, so any
  crate touching `AtomicU64` fails to build. **The documented escape hatch
  `system.switch.enableNg = false` is GONE** as of nixpkgs 26.11 - the option now hard-errors
  with "no longer has any effect", because the Rust `switch-to-configuration-ng` is the only
  implementation left. The replacement is **`system.switch.enable = false`**, whose own docs
  describe it as "good for image based appliances where updates are handled outside the
  image" - exactly this project. See `nixos/configuration.nix` and §6.1.
  Watch for Rust re-entering sideways: `nixos-generate-config` references `bcachefs-tools`,
  which is Rust, so the `system.tools.nixos-*` scripts must be disabled too.
- **There is no hwmon device on this board at all**, so fan control has no kernel-side input;
  it needs a userspace daemon polling drive SMART temps. For v1 the fan is pinned at a safe
  speed. Fan and poweroff are correctness issues on a 4-bay box, not polish.
- The `boot.initrd.enable = false` path uses `init=/nix/var/nix/profiles/system/init` — a
  store-independent path, which is what lets a cmdline baked into flash survive generation
  switches.

## Milestones

The status line at the top of `PORTING.md` tracks where things stand. **M3 is the go/no-go gate**: mainline kernel TFTP'd into RAM,
reaching a serial shell, all 4 bays enumerating, ethernet up. Everything before M3 is
reversible. If M3 fails, the instruction is to stop and reassess rather than work around it.

When work completes, tick the corresponding checkbox in `PORTING.md` and record the evidence
(command output, measured sizes) rather than just marking it done.
