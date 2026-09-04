# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Porting mainline Linux + NixOS onto a Synology DS410j (Marvell Kirkwood 88F6281,
armv5tel, 118 MB usable RAM, **Marvell U-Boot 1.1.4** bootloader, 4 MB SPI NOR flash).

**Status: working.** The box cold-boots unattended to NixOS 26.11 on kernel 6.12.104 -
serial login and ssh, `systemctl is-system-running` reports `running` with zero failed
units. There are nix builds for the kernel (`kernel/`), U-Boot (`uboot/`) and the
cross-compiled NixOS image (`nixos/`), plus bench helper scripts and verified flash
backups. The only tests are `nixos/test-fan-control.sh` (40 assertions against a
fake sysfs).

Fan control, the bay LEDs and the front panel **work and are boot-tested on the
hardware** (2026-09-03; evidence in `PORTING.md` §0). Remaining work is in
`PORTING.md` §7: warm reboot, per-bay activity LEDs, and LUKS.

**Bay LED pins are one bi-colour LED per bay, not two lamps.** Even pin = amber
(always), odd pin = green (only with a drive fitted), **both high = dark**.
`gpio-leds` cannot express that constraint, so anything writing those pins must
keep them mutually exclusive - `nixos/ds410j-fan-control.sh` does, with a
regression test. Amber is the only colour an empty bay can show.


**The power button is solved** (`PORTING.md` §7.1): it is **not a GPIO**. Holding
it ~4 s makes the board MCU send one byte, **`0x30`**, on UART1; a short press
sends nothing, which is why fourteen GPIO candidates were searched for nothing.
Confirmed working on our own kernel.

**`nixos/synology-mcu/` is the driver for it** — an out-of-tree serdev module
that turns MCU bytes into input events (`KEY_POWER`), exposes the two front-panel
lamps as LED class devices, and offers a debugfs `send`/`rx`/`counters` interface
for experimenting with the half-mapped protocol. Built and verified, **not yet
flashed**. It **takes over UART1, so `/dev/ttyS1` stops existing**:
`ds410j-mcu.sh` writes via debugfs first and falls back to the tty, and
power-off is unaffected because that goes through mainline's `qnap-poweroff` on
a separate DT node, never the tty. Full detail in `OPERATIONS.md`.

**Two things remain parked mid-investigation** and are listed at the top of
`PORTING.md` under "Unfinished, and easy to forget": the inconclusive **kwboot**
test, and **power-on after AC loss**, whose restore-last-power-state theory now
has a counter-example (a running box was cut and stayed off until someone pressed
the button) — so **a remote `ds410j-power.sh cycle` cannot be relied on to bring
the box back**. Read that list before starting anything new.

**The box can be power-cycled remotely** - `kernel/ds410j-power.sh cycle`. Working
theory (§3.3, small sample): the MCU restores the last power state, so cutting AC
on a **running** box brings it back, but a **soft-off** box stays off and only the
front-panel button revives it. So the command that strands the box is
`systemctl poweroff`, not the outlet - never issue it remotely. Also: the 433 MHz
radio reaches **every outlet in the house**, so the address in
`ds410j-power.sh` is hardcoded and must never be parameterised. None of this
helps with flashing the USB stick, so a bad image still needs a human.

**The board MCU is a mapped command channel** (`/dev/ttyS1`, 9600 8N1, single ASCII
characters). `0x31`-`0x3B` is fully mapped: `1` power off, `2`/`3` beep, `4`/`5`/`6`
power LED steady/blink/off, `7`-`;` status LED. It owns the status and power lamps
and the buzzer - which is why those are *not* GPIOs and cannot be `gpio-leds` - and
it is a live lead on warm reboot, since `poweroff` already works by sending it `1`.
`nixos/ds410j-mcu.sh` is the only writer in the system and takes an allowlist, so
no service can power the box off by getting a character wrong. Full table in
`OPERATIONS.md`, "The board microcontroller on /dev/ttyS1". **Never send it an
unidentified character unattended:** every reset needs a human at the button.

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
- **Our U-Boot switches the fans OFF unless patched** (§5.3). The fan is a 3-bit GPIO
  speed select on GPIO0 15/16/17 where 0 = off; the ds109 MPP table leaves those pins
  as **inputs**, which the fan reads as 0. U-Boot pins a safe speed in `board_init()`.
  **Any U-Boot built without that patch must not be left running with drives fitted.**
  §5.3's old "the fans run from hardware default" is true only for the stock-loader
  path, which is not the path we ship.
  Linux *can* now recover it, which it previously could not: both
  `CONFIG_SENSORS_GPIO_FAN` (absent from nixpkgs' armv5 defconfig, so there was no
  gpio-fan driver at all) and the `alarm-gpios` property that made the DT node fail to
  probe with -524 are fixed. That does **not** retire the U-Boot patch — it only
  shortens the window in which the fans are off, from "forever" to "until Linux
  starts".
- `bootdelay` is 3 s and **cannot be changed persistently** — the stock loader has no
  `saveenv`, so all `setenv` changes are RAM-only. A power cycle always returns to a
  known-good stock configuration.
- A modern U-Boot is chainloaded from the stock U-Boot into the freed `zImage` slot; it
  never replaces the stock loader. Verified working in RAM (`PORTING.md` §5.1).
- **Warm reboot does not work *yet*** — neither Linux nor U-Boot 2026.07 can reset
  this SoC, but **DSM reboots this board successfully**, so a mechanism exists and
  we have not found it. Do not treat it as impossible.
  A power cycle is still required, but the box **powers itself on when AC is
  restored**, and a remote outlet is now wired and verified
  (`kernel/ds410j-power.sh`). What enabled that behaviour is unknown (§3.3) - do
  not assume it survives a different MCU poke.
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
3. ~~**Hand-written DTS.**~~ **Resolved, then written anyway:** mainline's
   `kirkwood-ds409.dts` declares `synology,ds410j` and does boot this board, which is
   what unblocked bring-up. It describes a DS409 though, so `nixos/kirkwood-ds410j.dts`
   now exists for four measured defects (`PORTING.md` §7.1) — swapped bay LED colours,
   a fifth bay, a gpio-fan node that cannot probe, and eth1/native-SATA fighting over
   MPP21. It is compiled standalone by `nixos/device-tree.nix`, *not* added to the
   kernel tree, so editing it costs seconds rather than a full cross build.

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
- **There IS a board temperature sensor** - an LM75-compatible part at I2C 0x48, found
  by reading DSM (PORTING.md §3.3). It was believed absent for most of the project,
  which is why fan control is built on `CONFIG_SENSORS_DRIVETEMP` (per-drive temps)
  rather than on the board sensor or an in-kernel thermal zone. Both are now possible:
  the sensor has `#thermal-sensor-cells` and gpio-fan has `#cooling-cells`. Fan and
  poweroff are correctness issues on a 4-bay box, not polish.
- The `boot.initrd.enable = false` path uses `init=/nix/var/nix/profiles/system/init` — a
  store-independent path, which is what lets a cmdline baked into flash survive generation
  switches.

## Milestones

The status line at the top of `PORTING.md` tracks where things stand. **M3 is the go/no-go gate**: mainline kernel TFTP'd into RAM,
reaching a serial shell, all 4 bays enumerating, ethernet up. Everything before M3 is
reversible. If M3 fails, the instruction is to stop and reassess rather than work around it.

When work completes, tick the corresponding checkbox in `PORTING.md` and record the evidence
(command output, measured sizes) rather than just marking it done.
