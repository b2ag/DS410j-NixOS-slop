# NixOS on Synology DS410j — Porting Brief

Mainline Linux + NixOS on a Synology DS410j: Marvell Kirkwood 88F6281, armv5tel,
128 MB RAM, 4 MB SPI NOR, Marvell U-Boot 1.1.4.

**Status: working.** The box cold-boots unattended to NixOS 26.11 on kernel
6.12.104, with a serial login and ssh, and nothing attached but a USB stick.
`systemctl is-system-running` reports `running`, zero failed units.

**Fan control and the front panel work (2026-09-03)** [CONFIRMED on hardware].
`nixos/kirkwood-ds410j.dts` replaces mainline's `ds409.dts`; the kernel gains
`SENSORS_GPIO_FAN` (absent from nixpkgs' armv5 defconfig, so there had been no
gpio-fan driver at all) and `SENSORS_DRIVETEMP`. Evidence from the first boot of
the new image:

```
Machine model: Synology DS410j            <- our DTS, not ds409
gpio-fan gpio-fan-150-15-18: GPIO fan initialized
hwmon0: gpio_fan   hwmon1: drivetemp   hwmon2: drivetemp
ds410j-fan: max drive temp 34C over 2/2 drive(s) -> 2200 rpm
ds410j-fan: max drive temp 35C over 2/2 drive(s) -> 2500 rpm
```

`dmesg | grep "already requested"` is empty (the MPP21 collision is gone) and
`devices_deferred` no longer lists `mv643xx_eth_port.1`. `/sys/class/leds` holds
8 entries, not 11. `systemctl is-system-running` reports `running`, zero failed
units. The bay-detection code was incidentally proven against a changed
configuration: with both drives moved to bays 1 and 3 it reported `sdb -> bay 1`,
`sdc -> bay 3` and skipped the USB stick.

`nixos/mcu-panel.nix` drives the front-panel power and status lamps through the
board MCU, so the power lamp now goes steady at boot instead of blinking forever.
`nixos/out/ds410j-nixos.img` is the deployable image.

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


## Unfinished, and easy to forget

Three things are parked mid-investigation. All are written up in full further
down; this list exists so they are not lost.

1. **kwboot / BootROM recovery — INCONCLUSIVE, retest wanted.** (§7.3,
   `OPERATIONS.md` "Is the board actually brickable?") One attempt was made and
   settled nothing: the stock U-Boot did not come up, and no prompt could be got
   afterwards with `tio` either, so it is unclear whether the BootROM answered,
   whether the wrapper interfered, or whether the serial path was simply wedged.
   Not yet tried: **without** `kernel/kwboot-test.sh`, i.e. raw
   `kwboot -b -t /dev/ttyUSB0`; and from a host with the USB serial adapter
   attached directly rather than passed through into this container, since QEMU
   USB passthrough is a plausible source of timing trouble for a protocol with a
   short handshake window. Worth answering because it re-grades §0.

2. **What set power-on-at-AC-restore — UNKNOWN.** (§3.3) The behaviour changed and
   the change is real; the cause is not known and the MCU is only one guess among
   several. It is useful and we would not want to undo it by accident, but we can
   neither reproduce it deliberately nor reverse it.

3. **The power button does not work, and finding it is the top priority.** (§7.1)
   DSM shuts the box down on a short press, so a mechanism exists. Every
   input-capable SoC GPIO has now been tested via `gpio-keys` except six, and the
   MCU never transmits. The best untried step is reading the **stock** loader's
   MPP configuration at the `Marvell>>` prompt (`md 0xF1010000 8`) and diffing it
   against the DS109 table our U-Boot applies — direct evidence instead of
   inference. Second: the six untested pins (MPP29/30/31/34/44/45) are drive
   power enables, so test them **with the bays empty**.

Everything else outstanding is in §7.
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
| hwmon | **LM75-compatible sensor at I2C 0x48** (11-bit, 0.125 C), plus per-drive `drivetemp`. Long believed absent - see §3.3 |
| Fan | 3-bit GPIO speed select on GPIO0 **15/16/17**; alarm on 18 is `gpo`-only, so unreadable (§5.3) |
| Bay LEDs | GPIO **36/38/40/42** = amber 1-4, **37/39/41/43** = green 1-4. One bi-colour LED per bay, the two pins anti-parallel: **both high = dark**. Green is gated on drive presence. Mainline has the colours swapped (§7.1) |
| Status + power LEDs | **not GPIOs** — driven by the board MCU over UART1 (`/dev/ttyS1`, 9600 8N1). LAN is PHY-driven (§7.1) |
| MCU | on UART1 `serial@12100`, 9600 8N1 = `/dev/ttyS1`. Single-ASCII commands, `0x31`-`0x3B` fully mapped: `1` power off, `2`/`3` beep, `4`/`5`/`6` power LED steady/blink/off, `7`-`;` status LED (§7.1) |
| Buzzer | on the MCU: `2` short beep, `3` long beep. No GPIO involved |
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

### 3.3 The board sensor we missed, and no working SoC reset

**There IS a temperature sensor on this board** [CONFIRMED]: an LM75-compatible
part at I2C **0x48**, on the same bus as the RTC. This section previously said
"there is no temperature sensor anywhere on this board", and the hardware table
said `hwmon: none at all`. Both were wrong for the entire project, and the error
was load-bearing: it is why fan control was built on `CONFIG_SENSORS_DRIVETEMP`
reading drive temperatures, and why this section claimed the kernel thermal
framework was unusable here because there was "nothing for a thermal zone to
read". That reasoning is void.

It was found by reading DSM rather than the hardware. `ds410j_synobios.ko`'s
`GetSysTemperature` is *implemented*, unlike the LED setters, and does:

```
mov r0, #0x48 ; mov r2, #2 ; bl mvI2CCharRead   ; then byte-swap and >>7
```

which is the textbook LM75 conversion at the canonical LM75 address. `i2cdetect`
confirmed a device at 0x48; instantiating the driver gave a live reading. On the
bench it reads ~47.7 C with the drives at 42 and 39 C - the board is the hottest
of the three, which is what a fan is actually there to fix.

`national,lm75b`, not `lm75`: the first two are 9-bit (0.5 C) in the Linux
driver, `lm75b` is 11-bit (0.125 C). A 9-bit part can only set bit 7 of the LSB;
a forced raw read of register 0 returned `lsb=0xa0`, bit 5 set. Typed as `lm75`
it reported 47500, as `lm75b` 47750. The exact part number is [VERIFY] - that
needs the markings - but LM75-register-compatible at >= 11 bits is established,
which is what the compatible string has to get right.

Now declared in `nixos/kirkwood-ds410j.dts` with `#thermal-sensor-cells = <0>`.
The `gpio-fan` node already carries `#cooling-cells = <2>`, so a device-tree
thermal zone binding the two is now possible - see §7.1.


**THE BOX NOW POWERS ON BY ITSELF WHEN AC RETURNS** (2026-09-03). It previously
needed a front-panel button press after every power cut; it no longer does.

**Reproducible on demand** [CONFIRMED]: a deliberate remote cycle via
`kernel/ds410j-power.sh` switched the outlet off (carrier 1 -> 0 in 2 s), waited
10 s, switched it back on (carrier 0 -> 1 in 4 s), and the box booted to a login
prompt with nobody touching it. **The cause, however, is still completely
unknown** [VERIFY].

Do not assume the MCU did it. Unmapped characters had been sent to the MCU around
that time and `q`/`w` were floated as a guess, but that is a guess and nothing
more — the bench log lived in `/root/mcu-map.txt`, which is a tmpfs on this image,
so the record was erased at the next reboot. Other explanations are equally open
and none has been ruled out:

- it may always have behaved this way under some conditions, and the earlier
  "needs a button press" attempts differed in a way nobody recorded;
- the remote socket may switch AC differently from pulling the plug;
- something in our own boot chain or in the stock U-Boot environment (mtd4);
- an MCU character, known or unknown;
- the kwboot attempts, which drove the UART during power-up.

What *is* established is only that the behaviour changed. Reproducing it
deliberately, or reversing it, is unsolved.

One thing follows, and it is worth having regardless of the cause.

**It makes remote power cycling possible, which changes the operating model.**
"Warm reboot does not work, so every reset needs a human at the button" has
constrained this project throughout — it is why iteration is slow and why a bad
image strands the box. With power-on-at-AC-restore, a remote-controlled mains
socket is a complete remote power cycle. That is a better answer than either
outstanding warm-reboot lead (an MCU reset character, or RTC auto-power-on), and
it is wired and working - see `OPERATIONS.md`, "Remote power control". Since we
still cannot explain why it started, `ds410j-power.sh` treats "off" as the
dangerous direction: `cycle` always ends by trying to switch ON.

Note what this does NOT establish. It is tempting to conclude the state lives in
the MCU and therefore that the MCU holds non-volatile settings — but that only
follows if an MCU character caused it, which is exactly what is unknown. Where
this setting lives is as open as what set it.
**Warm reboot does not work.** `systemctl reboot` completes the entire shutdown —
unmounts, swaps off, SCSI caches flushed — and then hangs at
`reboot: Restarting system`. Neither Linux nor U-Boot 2026.07 can reset this SoC;
the *stock* loader can, so the hardware path exists and mainline does not reach it.
Practical consequence: power-cycling after `Restarting system` is **safe**, but
every reset needs a human. **`poweroff` does work** [CONFIRMED] — the asymmetry is
that the QNAP power-reset path cuts power but cannot restart.

**There is now a concrete lead.** `poweroff` works because `qnap-poweroff.c`
writes the single character `1` to the board MCU on UART1. That MCU turns out to
be a general command channel — it also drives the front-panel status LED (§7.1) —
so the question is simply which character asks it to reset. DSM's shutdown path
sends an unidentified `t`, which is the first thing to understand.

The codes are contiguous ASCII, so nearby characters are likely to mean
something. Mapping them is worth doing, but *supervised*: one character at a
time, with someone watching the chassis and the sent byte logged before it goes
out, which is what `ds410j-bench.sh mcu probe` does. An unattended sweep is not -
`1` powers the box off, and every reset needs a human at the button.

- **Warm reboot: two live leads, neither tried yet.**
  1. **RTC auto-power-on.** `ds410j_synobios.ko` carries a whole
     `rtc_ricoh_set_auto_poweron` / `rtc_ricoh_rotate_auto_poweron` family, which
     is DSM's scheduled-power-on feature — so the RS5C372A's alarm output is
     wired to this board's power circuit [LIKELY]. `poweroff` already works. So
     `rtcwake -m no -s 60` followed by `poweroff` would be a self-service reboot
     built entirely from proven mechanisms, with no unidentified MCU bytes.
     `rtcwake` is already in the closure. Caveat: `rtc-rs5c372` registers via the
     deprecated `devm_rtc_device_register()` and no IRQ is wired, so
     `/sys/class/rtc/rtc0/wakealarm` does **not** exist — but `set_alarm` is in
     its `rtc_class_ops` and `/proc/driver/rtc` does show `alrm_time`, so the
     `RTC_WKALM_SET` ioctl should still reach the chip [VERIFY].
  2. **An MCU reset command.** The MCU cuts power for `1`, so pulsing it is
     plausible in the same silicon. Needs the character map (§7.1, and
     `OPERATIONS.md` "The board microcontroller on /dev/ttyS1").

  A watchdog in the MCU would serve the same end and cannot be ruled out.
  Established: nothing is armed by default — 2 h 48 min of uptime with `tx:0` and
  no reset. Not established: whether one can be *armed*. The MCU never transmits
  (`rx:0`), but that is not evidence against: a watchdog needs a timer and a way
  to act, not a way to talk, and this one already cuts power.

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
32-35, a different DTS node — and leaves them **as inputs**, which the fan reads
as speed `0` = off. Note this is a statement about pin *direction*, not value.
Whether driving all three low as **outputs** also stops the fan is [VERIFY]: the
pins provably reach `0 0 0` that way [CONFIRMED], but nobody was listening to the
chassis at the time, so the fan's response is unmeasured — see §7.1.

`kirkwood-ds409.dts` sets `gpio-fan-150-15-18` to `status = "okay"`, but the node
cannot probe, so the pins keep whatever U-Boot left. This was invisible during
early bring-up because that kernel was booted straight from the *stock* loader,
which leaves the fans running.

The probe failure is `-524` = `-ENOTSUPP`, and the mechanism is worth recording
because the obvious reading of it is wrong [CONFIRMED, read from the 6.12.104
source]. It is **not** `setup of GPIO alarm failed` — that string is from a
pre-2016 `gpio-fan.c` and appears nowhere in 6.12. The real path is:

- the node carries `alarm-gpios = <&gpio0 18>`;
- `gpio_fan_get_of_data()` requests it with `devm_gpiod_get_optional(dev,
  "alarm", GPIOD_IN)` — an **input**;
- `pmx_fanalarm_18` muxes MPP18 as `"gpo"`, and MPP18 on the 88F6281 has no
  `"gpio"` function at all, only `"gpo"` (`pinctrl-kirkwood.c`, `MPP_MODE(18)`);
- `mvebu_gpio_set_direction()` finds the setting has `MVEBU_SETTING_GPO` but not
  `GPI` and returns `-ENOTSUPP` (`pinctrl-mvebu.c`).

So the alarm line is **unreadable on this SoC** and the property has to be
deleted rather than corrected. Two useful consequences: the failure happens in
`gpio_fan_get_of_data()`, *before* `fan_ctrl_init()` registers the
`gpio_fan_stop` devm action, which is why a failed probe leaves the fan spinning
rather than stopping it; and `fan_ctrl_init()` itself sets each pin to
`gpiod_direction_output(gpio, gpiod_get_value(gpio))`, deliberately preserving
the bootloader's speed, so a successful probe does not disturb the fan either.

**A correct device tree was never sufficient on its own.** nixpkgs' armv5
defconfig leaves `CONFIG_SENSORS_GPIO_FAN` unset, so the running NixOS kernel had
no `gpio-fan` driver at all — the platform device existed with nothing bound to
it. Both halves are now fixed: `nixos/configuration.nix` sets
`SENSORS_GPIO_FAN = yes` (built in, not a module — the devm action means an
`rmmod` would stop the fans) and `nixos/kirkwood-ds410j.dts` deletes
`alarm-gpios`.

`board_init()` pins a safe speed (3 = 3300 rpm; `DS410J_FAN_SPEED`). Data is
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

No custom DTS was needed to *boot*: `kirkwood-ds409.dts` declares
`synology,ds410j` and the kernel reported `Machine model: Synology DS409,
DS410j`. That is what unblocked bring-up, and it stays the fallback.

We now ship our own anyway — `nixos/kirkwood-ds410j.dts`, for four measured
defects (§7.1). It is compiled **standalone** by `nixos/device-tree.nix` rather
than added to the kernel tree, because the kernel is a from-source cross build
with no binary cache (§3.4): in-tree would mean a full rebuild per DTS edit, this
way it is seconds. `hardware.deviceTree.dtbSource` points at that one-file
derivation, so `/boot` carries a single 28 KB `.dtb` instead of mainline's 225,
which also took about 8 MB off the image.

**Watch the name, and the lack of a `marvell/` prefix.** The kernel source keeps
board files under `arch/arm/boot/dts/marvell/`, but the directory NixOS ships in
`/boot` is **flat**. Nothing catches a wrong `hardware.deviceTree.name` at build
time; it surfaces only as U-Boot failing to load the FDT. Verify against a built
image after any kernel bump — `debugfs -R "cat /boot/extlinux/extlinux.conf"` on
partition 2 shows the `FDT` line (`OPERATIONS.md`).
---

## 7. Open work

### 7.1 Board integration

- **A `kirkwood-ds410j.dts`.** **Done** — `nixos/kirkwood-ds410j.dts`, built
  standalone by `nixos/device-tree.nix` (not added to the kernel tree, so a DTS
  edit is seconds rather than a full cross build). `/boot` now carries one 28 KB
  `.dtb` instead of mainline's 225. It fixes four things `ds409.dts` gets wrong
  here, all [CONFIRMED] on the hardware:
  1. **Bay LED colours are swapped, and there is no fifth bay.** Walking every
     LED with drives in bays 2 and 4 gave `green:hddN` → the *amber* lamp for all
     four bays, and `amber:hddN` → the *green* lamp for bays 2 and 4 only. The
     "nothing" cases are exactly the empty bays, so the green lamp is gated on
     drive presence in hardware while amber is driven unconditionally. Even GPIO
     (36/38/40/42) = amber, odd (37/39/41/43) = green. GPIO 44/45 are a bay this
     chassis does not have.
  2. **`gpio-fan-150-15-18` cannot probe.** `alarm-gpios` is requested as an
     input on MPP18, which the 88F6281 offers only as `gpo` → `-ENOTSUPP`. Full
     mechanism in §5.3. The property is deleted; it cannot be corrected.
  3. **`sata@80000` and `eth1` both enabled and colliding.** `pmx_sata0` and
     `pmx_ge1` both want **MPP21** — the boot message is `pin PIN21 already
     requested by f1076000.ethernet-controller`, i.e. eth1 wins and the SoC SATA
     loses. (Recorded here as PIN20 until 2026-09-03; it is 21.) Neither belongs
     on this board: the four bays are behind the PCIe 88SX7042 and `ethphy1`
     (MDIO addr 9) is absent. Both are now `disabled`, which also clears
     `mv643xx_eth_port.1` out of `/sys/kernel/debug/devices_deferred`.
  4. `local-mac-address` is **not** set, deliberately. Our U-Boot passes the
     vendor MAC from mtd3 in via the `ethernet0` alias and `eth0` comes up as
     `00:11:32:02:f9:a6`, not the `00:00:5f:ff:00:00` fallback [CONFIRMED]. A
     hardcoded MAC would be wrong for every other DS410j and unupstreamable.

  Cosmetic, not fixed: the SPI flash node says `st,m25p80` for an M25P32;
  `jedec,spi-nor` probes it anyway.

- **Fan control.** **Working on hardware.** It needed two independent fixes, and
  the device tree was only one of them: nixpkgs' armv5 defconfig leaves
  **`CONFIG_SENSORS_GPIO_FAN` unset**, so the running kernel had no `gpio-fan`
  driver at all and a perfect DTS would still have given no control.
  `configuration.nix` now sets it (built in, not a module — see §5.3) along with
  **`CONFIG_SENSORS_DRIVETEMP`**, which turns each SATA drive's own sensor into
  an ordinary hwmon device and so removes the need for SMART tooling in a closure
  with no binary cache. `nixos/ds410j-fan-control.sh` closes the loop: hottest
  drive temperature → `fan1_target`. It never selects speed 0 and never parks the
  fan on exit; if a drive is present but yields no temperature it goes to full
  speed. `nixos/test-fan-control.sh` exercises all of it against a fake sysfs on
  the build host — 40 assertions, because the board needs a human to power cycle
  it (§3.3) and is a poor place to iterate.

- **Fan policy: quiet baseline, escalate on heat.** The first implementation
  tracked temperature continuously across six steps. That was wrong for this
  box: it re-evaluated every 30 s, so the fan was making constant small changes
  that are more audible than one steady speed, while saving nothing worth
  hearing at idle temperatures. It now holds a baseline and only reacts to real
  heat, with everything tunable in `services.ds410jFan`:

  | option | default | meaning |
  |---|---|---|
  | `baselineRpm` | `2200` | held until an input passes its threshold; a **floor**, never undercut |
  | `boardEscalateAboveC` | `55` | board sensor temperature at which ramping starts |
  | `boardWarnC` | `70` | board temperature that turns the status lamp orange |
  | `driveEscalateAboveC` | `50` | hottest drive temperature at which ramping starts |
  | `stepEveryC` | `3` | one speed step per this many degrees above that |
  | `hysteresisC` | `3` | return to baseline only this far below the threshold |
  | `driveWarnC` | `55` | amber bay LED and orange status lamp |
  | `pollSeconds` | `30` | |

  The baseline defaults to the **quietest** speed, not to the 3300 rpm U-Boot
  pins. That figure is an arbitrary safe-speed pick from bring-up
  (`uboot/default.nix`, `DS410J_FAN_SPEED`) and sits 4th of 7 on the speed map -
  it is not a hardware default, and anchoring to it would only inherit a guess.
  Drives idle around 35 °C and are rated to 55-60 °C, so there is ample headroom.

- **The board sensor changes what fan control could be.** An LM75-compatible part
  at I2C 0x48 (§3.3) is now declared in the DTS, so `/sys/class/hwmon/*/temp1_input`
  gives a board temperature alongside the per-drive `drivetemp` ones. Two things
  follow, neither done:
  1. `ds410j-fan-control.sh` steers on drive temperature only. The board reads
     hotter than either drive (47.7 C vs 42/39 on the bench), and it is the
     ambient the fan actually moves, so it is arguably the better input - or the
     daemon should take the max of both.
  2. **In-kernel thermal control is now possible.** The sensor carries
     `#thermal-sensor-cells = <0>` and `gpio-fan` carries `#cooling-cells = <2>`,
     which is everything a device-tree `thermal-zones` node needs to bind them
     with trip points and a governor. That would move fan control out of
     userspace entirely and keep it working even if the daemon dies - a real
     robustness gain on a box whose only reset is a power cut. The daemon would
     still be wanted for the bay LEDs.
- **The fan cannot be switched off by driving the pins low** [VERIFY]. The pins
  provably reach `0 0 0` from userspace, but the chassis was not being listened
  to at the time. If this holds it *softens* §0's fan rule: the hazard would be
  leaving the pins as **inputs** (what an unpatched U-Boot does), not any value
  written to them. Re-test with `ds410j-bench.sh fan step`, select `0`, wait 15 s.

- **LEDs: the status and power lamps are real and controllable, just not GPIOs**
  [CONFIRMED]. Neither MPP12 (what `gpio-leds-alarm-12`'s pinctrl selects) nor
  GPIO 21 (what its `gpios` property names) lights anything, and DSM's
  `ds410j_synobios.ko` — recovered from `flash-backup/mtd2.bin`, byte-identical
  to the copy on DSM's system partition, so it *is* the real module — implements
  `SetAlarmLed`, `SetPowerLedStatus`, `SetHDDActLed` and `SetPhyLed` as bare
  `mov r0,#0; bx lr` stubs. Mainline's `gpio-leds-alarm-12` is therefore spurious
  here and the node is disabled.

  **They belong to the board microcontroller** on UART1 (`serial@12100`, 9600
  8N1, `/dev/ttyS0`'s sibling `/dev/ttyS1`) — the same MCU mainline already pokes
  to power off. `synobios_ioctl` contains a raw passthrough that copies 16 bytes
  from userspace and calls `syno_ttys_write(1, buf)`. Commands are single ASCII
  characters, and `0x31`–`0x3B` is now a **fully mapped contiguous block**: `1`
  power off, `2`/`3` short/long beep, `4`/`5`/`6` power LED steady/blinking/off,
  `7` status off, `8`/`9` status green static/blink, `:`/`;` status orange
  static/blink. The status codes came from DSM's
  `/usr/syno/share/synogrinst/grinst-common.sh`; the rest were measured on this
  board. Full table and safety notes in `OPERATIONS.md`.

  `4`/`5` explain the front panel's default behaviour: the MCU blinks the power
  lamp until something tells it the OS is up, which is exactly what DSM does at
  the end of boot. `nixos/mcu-panel.nix` now does the same, and
  `ds410j-fan-control.sh` drives the status lamp orange on the same fault
  condition as the amber bay LEDs. `nixos/ds410j-mcu.sh` is the only writer and
  accepts an allowlist of safe codes — it **cannot** send `1`, so no system
  service can power the box off by getting a character wrong.

  Unmapped: letters. `t` appears in DSM's shutdown path and is unidentified;
  `k`/`l` are wake-on-LAN, not LEDs. If a reset command exists it is most likely
  a letter, since the protocol otherwise uses plain printable characters.

- **Bay LED colour mapping confirmed on all four bays** [CONFIRMED]. Bays 2 and 4
  came from the original LED walk; bays 1 and 3 were settled by moving both
  drives there, at which point those greens lit and 2/4 went dark. Presence
  gating confirmed in both directions. GPIO 44/45 tested and light nothing.

- **The two pins of a bay are one bi-colour LED, not two lamps.** All four
  combinations, [CONFIRMED] on hardware:

  | even pin (36/38/40/42) | odd pin (37/39/41/43) | result |
  |---|---|---|
  | high | low | **amber**, whether or not a drive is fitted |
  | low | high | **green**, but only with a drive fitted - empty bay stays dark |
  | high | high | **dark** |
  | low | low | dark |

  Two independent LEDs both driven would light, not go dark, so this behaves as
  one anti-parallel bi-colour LED with the green direction's return path routed
  through the drive connector [LIKELY mechanism]. The asymmetry is what produced
  the two "nothing" rows in the original walk.

  This bit: `update_leds` originally set green from presence and amber from
  temperature independently, so a drive that was present *and* too hot got both
  pins high and showed **nothing at all** - precisely the case that most needs a
  lamp. They are now mutually exclusive with amber winning, and
  `test-fan-control.sh` has a regression test. Anything else driving these pins
  needs the same rule; there is no DT binding that expresses the constraint, so
  `gpio-leds` cannot enforce it.

  Useful corollary: **amber is the only colour an empty bay can show**, which is
  what would make "expected drive missing" expressible if we ever want it.
- **Per-bay disk-activity LEDs need userspace.** 6.12's `disk-activity` trigger
  is global: one call site, `ledtrig_disk_activity(bool write)` in
  `libata-core.c`, with no device parameter, so binding it to all four greens
  blinks them in unison. `ledtrig-blkdev` was proposed upstream but is not in
  6.12. Doing it per bay means polling `/proc/diskstats` — one file read gives
  all four bays — at a few Hz. Not done; the daemon currently drives green as
  steady "drive present". One upside of the global trigger: it is libata-only,
  so the USB boot stick would not blink it.

- **Reboot.** §3.3. `orion_wdt` loads but its restart handler does not take effect.
  Since `poweroff` *does* work through the board's microcontroller, the likely
  avenue is that the same MCU accepts a reset command — worth tracing what the
  Synology variant of `POWER_RESET_QNAP` does [VERIFY]. For a headless 24/7 NAS
  this matters as much as poweroff did.
- **The front-panel buttons are still not visible to software** [CONFIRMED for
  everything tested; one gap remains, below]. DSM shuts this box down cleanly on
  a short press [CONFIRMED by the owner, twice], so a mechanism exists. We have
  not found it.

  | tried | result |
  |---|---|
  | MCU on UART1, `mcu listen`, power **and** reset pressed | `rx:0` — never transmits |
  | ...same, after `4` told the MCU the system was up | `rx:0` |
  | 10-second hold on the power button | nothing; the MCU does not act either |
  | I2C bus | only the RTC (0x32) and the LM75 (0x48) |
  | `gpio-keys` round 1: MPP12, 20, 21 | no events |
  | `gpio-keys` round 2: MPP4, 22-28, 32, 35, 46-49 | no events |
  | DSM kernel, 6883 symbol strings | no button/gpio-keys/`KEY_*` anywhere |
  | DSM `SYNO_CTRL_*` (10 entries) | LEDs, fan, buzzer, HDD power — no button |
  | `synoinfo.conf` | `usbcopy="no"`, no `support_*button*` key |

  Ruled out by construction, not by test: MPP5, 7, 18, 19, 33 are `gpo` on every
  88F6281 variant and can never be an input; 0-3, 8-11, 13-14 are SPI/i2c/uart;
  15-17 and 36-43 are the fan and bay LEDs.

  **The one gap: MPP29, 30, 31, 34, 44, 45.** All six ARE gpio-capable on the
  6281, and all six are untested — they were excluded because
  `kirkwood-synology.dtsi` names them `pmx_hdd*_pwr_*`, drive power enables, and
  flipping a live one to input could cut power to a fitted disk. That exclusion
  was right, but it means the search is not actually exhaustive. Testing them
  safely means doing it **with the bays empty**.

  **The best untried lead is the stock bootloader's own pinmux.** Our U-Boot is
  `ds109_defconfig` and applies the DS109 MPP table, which is why MPP12/20/21
  were unreadable in the first place. The *stock* Marvell U-Boot configures MPP
  for a real DS410j. Interrupt it at the `Marvell>>` prompt and read the mux
  registers directly:

  ```
  md 0xF1010000 8        # MPP_CTRL0..7, 4 bits per pin
  ```

  Any pin the stock loader sets to gpio that ours does not is a candidate, and
  this is direct evidence about the actual hardware rather than inference from
  another board's table. It has never been done. `/dev/mem` cannot substitute -
  `CONFIG_STRICT_DEVMEM=y` blocks MMIO from Linux.

  Also untried: whether the MCU needs an unmapped command to *enable* button
  reporting. Against that theory - the MCU looks like a timing peripheral (it
  owns LED blink rates and beep lengths autonomously, with no host traffic while
  a lamp blinks), and such a device plausibly was never designed to report
  anything, which would explain `rx:0` as intent rather than defect.
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

- **kwboot: is this board actually brickable?** [VERIFY, and it would rewrite §0]
  The safety model rests on mtd0 being "the only recovery path short of a SOIC
  clip". The 88F6281 has a mask-ROM BootROM that, per `kwboot(1)`, polls UART0 on
  every power-up for a handshake that starts an xmodem upload; U-Boot's `kwboot`
  implements it and names Kirkwood explicitly, citing the 88F6281 functional spec
  ch. 24.2. If it answers here, the SoC has a recovery path **no flash write can
  damage**, and the worst case drops from desoldering the SPI chip to plugging in
  a serial cable.

  `kernel/kwboot-test.sh` probes it and writes nothing — handshake only, no image
  uploaded, worst case a power cycle. It must be running *before* the board is
  powered on, because the polling window is short.

  If it works, §0's rules should be re-graded rather than deleted: mtd0 stays the
  cheaper recovery so "never `bubt`" remains sound practice, but the
  catastrophic-risk tier disappears and things currently ruled out — reflashing
  mtd0 with our own loader, collapsing the two-stage chain — become merely
  inconvenient rather than terminal. That is a bigger change to this project's
  shape than anything else outstanding, which is why it is worth an early answer.

  Caveat: it only helps with a serial console attached. That is always true on
  this bench and never true for a box in a cupboard.

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
