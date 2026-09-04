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

The **stock** bootloader's env is RAM-only (no `saveenv`), so `ipaddr`/`serverip`/
`netmask` must be re-set after every power cycle when working at the `Marvell>>`
prompt. Our U-Boot has a real environment in mtd4 and remembers them.

### Physical state of the bench

Worth knowing before interpreting anything, and easy to get wrong from a log alone:

- **Drives in bays 2 and 4** (two Toshiba DT01ACA300 3 TB). They enumerate as `ata2`
  and `ata4`, with `ata3: SATA link down` for the empty bay. Bays 1 and 3 were used
  earlier; the mapping is 1:1 either way.
- **The USB stick is the boot device**, written from `/src/nixos/out/ds410j-nixos.img`.
  It appears as `sda` in Linux, ahead of the SATA disks.
- The box takes a DHCP lease from the bench dnsmasq (192.168.50.100-200), so its
  address is **not** the `192.168.50.50` that U-Boot uses.
- Root password on the serial console is `ds410j` - a v1 placeholder, see
  `nixos/configuration.nix`.
- **ssh from this container** works and is much faster than the serial console for
  anything non-boot. A key was installed via serial into `/root/.ssh/authorized_keys`:
  ```sh
  ssh -i ~/.ssh/ds410j root@192.168.50.138
  ```
  The address is the DHCP lease, not the `192.168.50.50` U-Boot uses; check it with
  `ip neigh show dev eth1` and look for the vendor MAC `00:11:32:02:f9:a6`. The key
  is bench convenience only — it is not in `configuration.nix`, so a reflash of the
  USB stick loses it and it has to be re-added over serial.

## Helper scripts (`/src/kernel/`)

| Script | Purpose |
|---|---|
| `serlog.sh` | The serial logger. `exec cat $SERIAL_DEV >> logs/serial.log`. Start with `setsid`. |
| `sercmd.sh "<cmd>" [secs]` | Send a command, print only the newly captured output. |
| `spam.sh [secs]` | Spam spaces at the console to interrupt autoboot (`bootdelay=3`). |
| `dump-flash.sh` | Dump all six MTD partitions over ethernet and verify against device md5. |
| `init.sh` | The initramfs init baked into the bring-up kernel. |
| `install-bench.sh` | Cross-build libgpiod and push it plus `ds410j-bench.sh` to the box. |
| `ds410j-bench.sh` | **Runs on the DS410j, not here.** Drive the fan, LEDs and MCU by hand; `led bay N` shows the anti-parallel wiring. |
| `kwboot-test.sh` | Probe the SoC BootROM UART recovery path. Writes nothing. |
| `ds410j-power.sh` | Remote mains switch via the 433 MHz outlet. `cycle` is the safe verb. |

Typical session start:

```sh
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts -ixon -ixoff raw -echo
setsid /src/kernel/serlog.sh & disown
```


## Driving the fan and LEDs by hand

`kernel/ds410j-bench.sh` is the odd one out in that directory: it runs **on the
DS410j**. Deploy it, together with a cross-built libgpiod, with:

```sh
/src/kernel/install-bench.sh          # DS=192.168.50.138 KEY=~/.ssh/ds410j to override
```

Then from a root shell on the box:

```sh
/root/ds410j-bench.sh fan get         # current 3-bit speed select, decoded
/root/ds410j-bench.sh fan step        # interactive: type 0-7, waits for you at each
/root/ds410j-bench.sh led walk        # lights each LED in turn, waits for you at each
/root/ds410j-bench.sh led set synology:green:hdd2 1
```

It talks to the GPIO character device directly rather than through `gpio-fan`,
which is the whole point: it has to work on a kernel where
`CONFIG_SENSORS_GPIO_FAN` is unset, and that was exactly the kernel that made the
tool necessary. `fan step` prints the pins read back after every change, so it
cannot claim a speed it failed to select.

Two things about libgpiod worth knowing before you trust a reading:

- **`gpioget` defaults to forcing the line to input.** On the fan pins that
  would drop the speed select. Always pass `--as-is`; the bench script does.
- **`gpioset` holds the lines until it exits, then warns the state is "not
  guaranteed".** On mvebu it is in practice: released pins keep both their
  direction and value (verified — set `0 0 0`, let `gpioset` exit, read back
  `0 0 0`). That is why `fan set` can use a one-second `timeout` and still latch.

Everything the box needs at runtime is in the system closure; libgpiod lives in
`/root/gpiod` and is deliberately *not* part of it.


### Verifying fan and LED control after a reboot

The board needs a human to power cycle it, so it is worth getting everything out
of one boot. In order:

```sh
# 1. the right device tree loaded
cat /proc/device-tree/model                 # -> "Synology DS410j", not "DS409, DS410j"

# 2. the MPP21 collision is gone, and eth1 is no longer deferred
dmesg | grep -i "already requested"         # -> nothing
cat /sys/kernel/debug/devices_deferred      # -> no mv643xx_eth_port.1

# 3. gpio-fan probed and is bound to a driver
ls /sys/bus/platform/drivers/gpio-fan/      # -> gpio-fan-150-15-18 symlink
grep -l gpio_fan /sys/class/hwmon/*/name    # -> the fan's hwmon
dmesg | grep -i "GPIO fan"                  # -> "GPIO fan initialized"

# 4. drive temperatures are readable
for h in /sys/block/sd*/device/hwmon/hwmon*/temp1_input; do
  echo "$h $(cat $h)"; done                 # -> milli-C per SATA drive

# 5. the daemon is running and has picked a speed
systemctl status ds410j-fan-control
journalctl -u ds410j-fan-control            # -> "max drive temp NNC ... -> NNNN rpm"

# 6. front panel, via the MCU
systemctl status ds410j-panel               # -> active (exited)
#    blue power LED should now be STEADY, not blinking - that is the
#    ds410j-panel unit having sent '4' once multi-user.target was reached.
#    Status LED should be green.

# 7. LED colours are now the right way round
/root/ds410j-bench.sh led set synology:amber:hdd2 1   # -> AMBER lamp, bay 2
/root/ds410j-bench.sh led set synology:green:hdd2 1   # -> GREEN lamp, bay 2
/root/ds410j-bench.sh led all 0

# 8. nothing regressed
systemctl is-system-running                 # -> running
systemctl --failed
```

**Bay LED wiring.** The two pins of a bay drive one bi-colour LED, not two lamps:

| even pin (36/38/40/42) | odd pin (37/39/41/43) | result |
|---|---|---|
| high | low | **amber**, with or without a drive |
| low | high | **green**, only with a drive fitted |
| high | high | **dark** |
| low | low | dark |

So an empty bay can show amber but never green, and setting both pins is the
same as setting neither. `ds410j-bench.sh led bay N` walks all four combinations,
waiting at each. Stop `ds410j-fan-control` first or it re-asserts them every 30 s.

Expect `/sys/class/leds` to hold **eight** entries after this, not eleven: the
`hdd5` pair and `synology:alarm` are gone. That is not because those lamps do not
exist — the status lamp very much does — but because they are not GPIOs and so
cannot be `gpio-leds`. They live on the MCU instead; see "The board
microcontroller on /dev/ttyS1" above, and PORTING.md §7.1.

**GPIO 44/45 (mainline's `green:hdd5` / `amber:hdd5`) are still untested.** On a
4-bay chassis those two pins are unaccounted for, so before trusting the eight-LED
figure it is worth checking them on a kernel that still declares them — i.e.
*before* reflashing, not after:

```sh
/root/ds410j-bench.sh led set synology:green:hdd5 1     # anything?
/root/ds410j-bench.sh led set synology:amber:hdd5 1
/root/ds410j-bench.sh led all 0
```

A caution on step 3: if `gpio-fan` fails to probe, the fan keeps whatever U-Boot
set (3300 rpm) rather than stopping - the failure happens before the driver
touches the pins. So a broken probe is safe but silent; check for it rather than
assuming the fan is under control because the box is not on fire.



## Remote power control

The DS410j is on a 433 MHz mains outlet driven by a host-side transmitter. The
guest reaches it through a second QEMU serial port, `/dev/ttyS1` at 9600 8N1, on
which the host listens for whole lines.

```sh
/src/kernel/ds410j-power.sh status
/src/kernel/ds410j-power.sh cycle      # off, 10s, on - verified
/src/kernel/ds410j-power.sh on
```

**The dangerous command is `poweroff`, not the outlet.** This is the opposite of
what it looks like, so it is worth stating plainly:

- **`cycle` from a running box is safe.** Cutting AC and restoring it brings the
  box back on its own - four for four so far. This is the working theory in
  PORTING.md §3.3 (restore-last-power-state), not a guarantee; the sample is
  small.
- **A soft-off box cannot be recovered remotely at all.** `systemctl poweroff`,
  or DSM shutting down, leaves the MCU remembering "off". Cycling the outlet then
  does nothing - the relay clicks and no LEDs come on. Only the front-panel
  button revives it.

So the one action that guarantees needing a human is issuing `poweroff` over ssh.
The outlet is not the hazard; the soft power-off is.
Three properties worth knowing before touching it:

1. **The radio reaches every outlet in the owner's home.** The address
   `m-FS300 1337 a` is hardcoded in the script and there is deliberately no
   option to override it. A mistyped address does not error - it switches
   something else in someone's house.
2. **The link is one-way.** `/dev/ttyS1` sends nothing back, and the transmitter
   is hand-built and does not work every time. So *nothing* is inferred from the
   write succeeding; every action is verified against
   `/sys/class/net/eth1/carrier` and retried up to three times. Carrier is the
   honest indicator of whether the box has power (gotcha 8).
3. **Commands need a trailing newline.** The host reads whole lines; without
   `\n` the command sits in the buffer and nothing happens.

Measured on the first verified cycle: carrier dropped 2 s after `off`, and came
back 4 s after `on`, with the box at a login prompt about 90 s later. The 45 s
on-timeout in the script has plenty of margin.

This does **not** help with flashing the USB stick, so a bad image still strands
the box until someone reflashes it.

## The board microcontroller on /dev/ttyS1

The DS410j has an MCU on **UART1** (`serial@12100`, mmio `0xF1012100`), exposed by
our kernel as **`/dev/ttyS1`**, **9600 8N1**. It owns the front-panel status and
power lamps and the power rail. Commands are **single ASCII characters** written
to the tty. This is the same MCU mainline's `qnap-poweroff.c` uses.

```sh
stty -F /dev/ttyS1 9600 cs8 -cstopb -parenb raw -echo
printf ';' > /dev/ttyS1        # status LED: orange, blinking
```

The channel is **bidirectional**: the MCU also *sends* one byte, and that is how
the front-panel power button reaches software (see below).

### Host -> MCU (commands)

| Code | Hex | Effect | Source |
|---|---|---|---|
| `1` | `0x31` | **POWER OFF** | mainline `qnap-poweroff.c` |
| `2` | `0x32` | buzzer, short beep | measured on this board |
| `3` | `0x33` | buzzer, long beep | measured on this board |
| `4` | `0x34` | power LED (blue) steady | measured on this board |
| `5` | `0x35` | power LED (blue) blinking | measured on this board |
| `6` | `0x36` | power LED (blue) off | measured on this board |
| `7` | `0x37` | status LED off | `grinst-common.sh` |
| `8` | `0x38` | status LED green, static | `grinst-common.sh` |
| `9` | `0x39` | status LED green, blinking | `grinst-common.sh` |
| `:` | `0x3a` | status LED orange, static | `grinst-common.sh` |
| `;` | `0x3b` | status LED orange, blinking | `grinst-common.sh` |
| `t` | `0x74` | **disable fan check** — DSM sends it on the shutdown path so the MCU does not raise a fan alarm as the fan stops | `syno_poweroff_task` + name table below |

### The `synology-mcu` kernel driver

`nixos/synology-mcu/` is an out-of-tree module that binds UART1 as a **serdev**
client. It turns the MCU's event bytes into input events, so a power-button hold
arrives as `KEY_POWER` and logind applies its normal policy — no daemon sitting
on a tty. [CONFIRMED working on hardware 2026-09-04.]

```
synology-mcu serial0-0: power button       <- MCU byte 0x30, ~4 s hold
systemd-logind[673]: Powering off...
reboot: Power down                         <- the driver's own poweroff handler
```

**It takes the port over: `/dev/ttyS1` no longer exists** once it binds. Two
things follow, and both are already handled:

- `ds410j-mcu.sh` writes to the driver's debugfs file first and only falls back
  to `/dev/ttyS1`, so `mcu-panel.nix` and the fan daemon are unaffected.
- **Power-off is the driver's job now.** It used to belong to mainline's
  `qnap-poweroff`, via a stand-alone `poweroff@12100` node in
  `kirkwood-synology.dtsi` — a second node at the same unit address as
  `serial@12100`, which is what made `dtc` warn about a duplicate. Our DTS
  deletes that node and the driver registers its own power-off handler.
  It writes the UART registers directly rather than using serdev, because a
  power-off handler runs after `device_shutdown()` and may be called with
  interrupts disabled: no tty, no sleeping. Same register sequence as
  `qnap-poweroff.c`. **If the module does not load, nothing cuts the board's
  power** — `systemctl poweroff` halts with the box still running. Recoverable
  by pulling the plug, but worth knowing.

What it gives you:

```sh
/sys/class/leds/synology:blue:power/brightness      # 4 / 6
/sys/class/leds/synology:green:status/brightness    # 8 / 7
/sys/class/leds/synology:amber:status/brightness    # : / 7
```

The two status colours are one physical lamp, so they are mutually exclusive —
lighting one clears the other, the same constraint the bay LEDs have. Only
on/off is exposed as a LED device: the MCU's *blinking* states are still sent as
raw bytes, because a LED `brightness_set` callback that talks to a 9600 baud UART
has to be the sleeping variant, and blink handling is not worth the complexity.

**The debugfs interface exists so the module never becomes the thing that blocks
experimenting.** Most of the command table below is inferred from another model,
so raw access stays available:

```sh
printf ';' > /sys/kernel/debug/synology-mcu/send   # status lamp amber, blinking
cat /sys/kernel/debug/synology-mcu/rx              # last 64 bytes, timestamped
cat /sys/kernel/debug/synology-mcu/counters        # per-event totals
```

`send` passes bytes through verbatim (one trailing newline is stripped, so
`echo 4 > send` does what it looks like). It refuses `1` and `p` — both cut
power, and a soft-off DS410j needs a human at the front panel. Load the module
with `allow_dangerous=1` if you mean it.

**Verbatim means verbatim.** Do not redirect stderr into this file:
`printf '1' > send 2>&1` put the shell's own error text through it, and the guard
refused a `p` out of "Operation not permitted". The whole buffer is rejected if
any byte in it is dangerous, so nothing was sent — but a message without a `1`
or `p` in it would have gone to the MCU character by character.

### The wider `UART2_CMD_*` table [VERIFY — external, mostly untested here]

`scemd` contains the string `Fan stop [UART2_CMD_CPUFAN_FAILURE]`, which says
Synology's GPL `synobios` source has a named `UART2_CMD_*` enum. A third-party
reverse-engineering write-up of that enum is at
<https://smallhacks.wordpress.com/2012/04/17/working-with-synology-hardware-devsynobios-and-devttys1/>.

**Every code we independently measured on this board matches it** — `0x31`
shutdown, `0x32`/`0x33` beeps, `0x34`-`0x36` power LED, `0x37`-`0x3B` status LED,
`0x30` power button, `0x61` reset button — which is good corroboration for the
rest. But it describes Synology hardware in general, not the DS410j, so treat
anything above `0x3B` as **[VERIFY]**: plausible, never tested here.

| Hex | Char | Name | Note |
|---|---|---|---|
| `0x3d` | `=` | `LED_HD_BREATH` | status LED breathing |
| `0x40` | `@` | `LED_USB_ON` | no USB LED on this box |
| `0x41` | `A` | `LED_USB_BLINK` | " |
| `0x42` | `B` | `LED_USB_OFF` | " |
| `0x4a` | `J` | `LED_10G_LAN_ON` | n/a here |
| `0x4b` | `K` | `LED_10G_LAN_OFF` | n/a here |
| `0x50` | `P` | `LED_MIRROR_OFF` | n/a here |
| `0x51` | `Q` | `LED_MIRROR_GS` | n/a here |
| `0x52` | `R` | `LED_MIRROR_AS` | also listed as `GET_UNIQUE_CMD` on x86 |
| `0x53` | `S` | `LED_MIRROR_AS` | n/a here |
| `0x54` | `T` | `LED_MIRROR_AB` | n/a here |
| `0x55` | `U` | `TOGGLE_FAN_RPS_REPORT` | **[MEASURED] nothing happens here** — no RPM reporting on this board, see below |
| `0x56` | `V` | `SET_PWM_DUTY` | our fan is a 3-bit GPIO speed select, so probably n/a |
| `0x57` | `W` | `SET_PWM_FREQ` | " |
| `0x6c` | `l` | `WOL_ENABLE` | the write-up notes it does not work on a DS207 |
| `0x43` | `C` | **RESTART** — not in the DS207 table | **[MEASURED]** warm reboot; the driver's `SYS_OFF_MODE_RESTART` handler sends it |
| `0x70` | `p` | `RCPOWEROFF` | **DANGEROUS — cuts power** |
| `0x71` | `q` | `RCPOWERON` | |
| `0x72` | `r` | `DISABLE_SCHEDULE_POWERON` | **a lead for §3.3** (power-on after AC loss) |
| `0x73` | `s` | `ENABLE_SCHEDULE_POWERON` | " |
| `0x74` | `t` | `DISABLE_FANCHECK` | **[MEASURED]** stops the alarm below; also what DSM sends on its shutdown path |
| `0x75` | `u` | `ENABLE_FANCHECK` | **[MEASURED] do not use — see below** |
| — | `"EC0"` | `DISABLE_CPUFANCHECK` | multi-character, unlike everything else |
| — | `"EC1"` | `ENABLE_CPUFANCHECK` | " |

**Fan checking is broken on this board — leave it off.** [MEASURED 2026-09-04.]
The behaviour is the exact opposite of what it looks like:

- With fan checking **off** (the default), disconnecting the fans produces no MCU
  traffic at all — two attempts, nothing.
- Enabling it with `0x75` `u` makes the MCU **spam `0x66` FAN_FAILURE
  continuously with the fans running perfectly well** — 34 events before it was
  turned off again.
- `0x74` `t` stops it immediately, and the counter freezes.

So the MCU's fan sense does not work on a DS410j, in either direction. That fits
the hardware: the fan here is a 3-bit GPIO speed select (`gpio-fan`), not
something the MCU drives, so it has no tacho to read and defaults to "failed".
It also explains why DSM sends `0x74` on its shutdown path — on this model the
check is useless and stays disabled.

**And there is no fan RPM reporting either.** [MEASURED 2026-09-04.] `0x55` `U`
(`TOGGLE_FAN_RPS_REPORT` in the DS207 table) produces **nothing at all** — not
with fan checking off, and not with it on. With `0x75` enabled the only bytes
that ever arrive are `0x66`, on a metronomic **~4.2 s poll**:

```
564.000157710  0x66  f  FAN_FAILURE
568.181650520  0x66  f  FAN_FAILURE
572.385400095  0x66  f  FAN_FAILURE
576.589471170  0x66  f  FAN_FAILURE
```

`unknown` stayed at 0 throughout, so no RPM payload of any kind was sent. The
regular interval is itself informative: the MCU *is* actively polling something
and consistently concluding "failed", which is what a tacho input with nothing
attached to it looks like.

So the MCU has no working fan sense on a DS410j in any form — no failure
detection, no RPM. That fits the wiring: the fan is a 3-bit GPIO speed select
with no tacho line back to the MCU. `0x66`/`0x67` are therefore **not** a usable
fan-failure signal here, and real fan monitoring stays with `gpio-fan` plus the
drive temperatures. The stock loader's `Fan Status: Good` banner is presumably
reading something else, or is simply unconditional.

**`C` (0x43) RESTARTS THE BOARD — this is warm reboot.** [CONFIRMED 2026-09-04,
reproduced 2/2.] It is not in the DS207 table. Found by accident: `"EC1"`
(supposedly *enable CPU fan check*) restarted the box, so did `"EC0"`, `E` alone
did nothing, and `C` alone did it. The driver now registers a
`SYS_OFF_MODE_RESTART` handler for it and **`systemctl reboot` works**. Full
write-up in PORTING.md §3.3.

So `"EC0"`/`"EC1"` restart the box too, by virtue of containing a `C`. They are
exempt from the guard when written as an exact three-byte write, but there is no
CPU fan check to be had here — sending them just reboots.

**Dangerous bytes, for the avoidance of doubt:** `0x31` (shutdown) and `0x70`
(remote power off) both cut power. `ds410j-mcu.sh`'s allowlist exists precisely so
no service can send one by accident.

### MCU -> host (events)

DSM's `scemd` recognises **exactly five** MCU->host bytes. The dispatch was read
straight out of the binary (`event_microp.c`, function `MicropEventHandler`, the
5-way compare at `0x1c37c`), so this table is complete, not a sample:

| Code | Hex | Meaning | How known |
|---|---|---|---|
| `0` | `0x30` | **front-panel power button held ~4 s** (a short press sends nothing) | pressed on this board + `"power button pressed, ret = 0"` |
| `` ` `` | `0x60` | **`UART2_CMD_BUTTON_USB`** — USB-copy button | `"USBcopy/Mute button pressed, Model error?"` — n/a here, `usbcopy="no"`, so this box takes the "Model error" branch |
| `a` | `0x61` | **rear reset button** (duration threshold not separately measured) | pressed on this board + `"reset button pressed, ret = 0"` |
| `f` | `0x66` | **`UART2_CMD_FAN_FAILURE`** — chassis fan failed | dispatch + fan strings in `scemd` + name table |
| `g` | `0x67` | **`UART2_CMD_CPUFAN_FAILURE`** — CPU fan failed | ditto; `scemd` contains the literal string `Fan stop [UART2_CMD_CPUFAN_FAILURE]` |

[CONFIRMED on both DSM and our own kernel.] **The MCU only reports a hold of
about 4 seconds. A short press is ignored completely — it puts nothing on the
wire at all.** The single byte is therefore *itself* the long-press event; there
is no short-press event to distinguish it from. One byte per qualifying hold, no
repeat while held, no byte on release, no hardware force-off. No GPIO pin moves
for any of it.

**This is what made the button look invisible for so long.** Every earlier test
press on our kernel was a short tap, so `rx` stayed `0` and it looked like the
MCU never transmitted to us. It always did. Three hypotheses were chased and all
three were wrong: the UART1 receive pin was fine, an unheld port was not the
cause, and no "arming" command exists. The only thing needed is to **hold the
button ~4 s** with something keeping `/dev/ttyS1` open.

**There is no handshake.** This was the obvious way the above could have been
wrong — those measurements were first taken with `scemd` frozen (`SIGSTOP`),
which by construction stalls any protocol that needs the host to reply. Retested
with `scemd` running normally under an `LD_PRELOAD` that logs both directions:

```
[13:33:37.541] READ  fd=8  : 30 '0'     <- MCU: button pressed
[13:33:38.641] WRITE fd=10 : 35 '5'     <- +1.10s  power LED -> blinking
[13:33:39.761] WRITE fd=10 : 33 '3'     <- +2.22s  long beep
[13:33:39.761] WRITE fd=10 : 35 '5'     <-         power LED -> blinking
```

The MCU said one byte and stopped. What the host writes back is not a reply, it
is the ordinary shutdown indication (`5` = power LED blinking, `3` = long beep)
from the command table above, and it comes a full second later. So the protocol
is one-way and the frozen measurements were sound.

Note the byte above arrived from a **hold**, not from the short press that
preceded it in the same test — the MCU had ignored the tap. `scemd`'s `0x30`
handler has no timer and no duration check because it does not need one: the MCU
has already applied the 4 s threshold in firmware, and the byte only ever means
"held long enough".

Note the fds: **`scemd` reads the MCU on one descriptor and writes it on
another** (8 and 10 here, both `/dev/ttyS1`). A tracer that keys on the fd the
read came from will see none of the writes while `tx` climbs.
DSM's `scemd` is the reader that turns it into a shutdown; freeze `scemd`
(`kill -STOP`) and the byte sits unread in the tty buffer with the box still up.
That test is what found it, and `/proc/tty/driver/serial` (`rx:` on line `1:`) is
the cheapest way to see the byte arrive without consuming it. Full write-up in
`PORTING.md` §7.1.

**DSM has a second, kernel-side route to this tty.** `synobios.ko` imports
`syno_ttys_write`, and its single call site is inside `synobios_ioctl`:
`syno_ttys_write(1, sp+4, ...)`. Walking the ioctl dispatch in that function
(the compare chain at the top branches to handler bodies; the body at `+0x128c`
is the one containing the call at `+0x1360`) identifies the command exactly:

```
ioctl(fd_of_/dev/synobios, 0xc0044b20, &val)     /* _IOWR('K', 0x20, int) */
```

That is a usable primitive in its own right: it writes a byte to the MCU from
kernel context. Note `scemd` itself never references `0xc0044b20` — the call
comes from a Synology shared library, not the daemon binary.

Consequences, all learned the hard way:

- An `LD_PRELOAD` shim on `read`/`write` sees nothing (it is an ioctl), and a pty
  man-in-the-middle on `/dev/ttyS1` sees nothing either (the kernel writes to the
  real 8250, not to our pty) — while the `tx` counter climbs the whole time.
- `ioctl` *is* interposable, unlike stdio. **But keep the shim tiny.** Wrapping
  `open`/`close`/`dup`/`read`/`write` as well, or classifying every fd with a
  `readlink` on `/proc/self/fd/N`, makes `scemd`'s main process fail to start —
  it forks, runs, answers ioctls, and never opens `/dev/ttyS1`, with nothing on
  stderr and nothing in syslog. A shim that only filters on a length or a
  request-number compare leaves `scemd` perfectly healthy. Three further traps in
  a `-nostdlib` shim: raw syscalls return `-errno` where every caller expects
  `-1` with `errno` set (pass the call through libc's `syscall()` instead);
  register-asm variables assigned late can be clobbered by the compiler; and
  **interposing `execve` does not stop a shutdown** — glibc's `execv`/`execl`
  reach `__execve` internally, so only a literal `execve()` call is caught. A
  press still powers the box off with such a block in place.
- The MCU->host direction is an ordinary tty read, which is why our `mcurx.py`
  could read `0x30` straight off `/dev/ttyS1`.

**Power-off does not go out over this tty from userspace.** A pty
man-in-the-middle that dropped every `1` on its way to the MCU did **not** stop
the box powering down: `scemd` just runs the normal `shutdown` path and the final
cut comes from the **kernel** (`pm_power_off`, as in mainline `qnap-poweroff.c`)
writing to the UART directly. Kernel-side writes bypass a userspace bridge, which
is also why the MCU's `tx` counter advances with nothing in the bridge log. Two
consequences: a userspace tap can only see *some* of the host->MCU traffic, and
any trace must be streamed off-box — a log in `/tmp` dies with the shutdown it
was recording (learned the hard way).

The old "`rx:0` — the MCU never transmits" finding was measured on **our** kernel,
not DSM's, and is still unexplained; the leading suspect is that MPP14 (UART1
**rxd**) is not muxed by our U-Boot's DS109 MPP table, since our DTS declares no
pinctrl for `serial@12100`. So a reader on our side is not yet known to work.

`0x31`–`0x3B` is a **complete contiguous block** [CONFIRMED]: power, buzzer, power
LED, status LED, in that order. `4`/`5` explain the front panel's normal
behaviour — DSM sends `4` when boot finishes and `5` during shutdown, which is
why a running-but-not-DSM box sits there blinking.

Symbols and letters outside this block are unmapped. `k`/`l` are wake-on-LAN
(`libsynosdk.so.5`), not MCU LED codes. If a reset command exists it is most
likely a letter — `q w e r ...` — since the protocol otherwise uses plain
printable characters; `t` already being in DSM's shutdown path is suggestive.

**Never send an unidentified character unattended.** `1` powers the box off
immediately, and every reset needs a human at the front-panel button
(PORTING.md §3.3), so a stray byte costs a trip to the bench. `t` appears in
DSM's shutdown path and is unidentified — leave it alone. Mapping the rest is
worth doing and there is tooling for it below; the rule is that a human watches
the chassis and the byte is logged before it is sent.

Where these came from, for anyone re-deriving them: DSM's system partition is
`/dev/sdc1`, a RAID1 member with **0.90 metadata**, which puts the superblock at
the *end* and so leaves the ext4 filesystem at offset 0. `mount` refuses it by
autodetection, but an explicit type works, and `noload` keeps it genuinely
read-only by skipping journal replay:

```sh
mount -t ext4 -o ro,noload /dev/sdc1 /mnt/dsm
grep -rn ttyS1 /mnt/dsm/usr/syno /mnt/dsm/lib
```

### Mapping it

`ds410j-bench.sh` has an `mcu` subcommand for this. It refuses `1` and `t`
without `--force`, and it **writes each character to the log before sending it,
then syncs** — so if a code kills the box, the log still names the culprit.

```sh
/root/ds410j-bench.sh mcu known          # confirm the documented codes, waits at each
/root/ds410j-bench.sh mcu send 8         # one character
/root/ds410j-bench.sh mcu probe 0x3c 0x40   # step a range, recording what you see
/root/ds410j-bench.sh mcu map            # print /root/mcu-map.txt
```

`mcu probe` demands a literal `YES` before it starts, then walks the range one
character at a time and prompts for an observation after each, appending it
immediately. Work in small ranges rather than one long sweep: the log survives a
power-off, but your place in the range does not.

Where to look first. The status codes occupy a contiguous block at `0x37`–`0x3B`
(`7 8 9 : ;`), so a second lamp is plausibly in an adjacent block — `0x3C`–`0x40`
(`< = > ? @`) or `0x32`–`0x36` (`2`–`6`). Two things are known to be missing and
worth wanting:

- **the power LED codes.** DSM makes the blue lamp steady when boot completes and
  blink during shutdown, so a "system ready" code exists.
- **a reset command.** The MCU already cuts power for `1`, so pulsing it is
  plausible in the same silicon, and it would close PORTING.md §3.3 — currently
  every reset needs a human at the button.

### Is there a watchdog in there?

Unresolved, and worth keeping an open mind about. What is established: **nothing
is armed by default** — the box ran 2 h 48 min with `tx:0` on this port and did
not reset. What is *not* established is whether one can be armed by a command we
have not identified. Note the MCU never transmits (`rx:0` even with the port held
open and after commands), but that is not evidence either way: a watchdog needs a
timer and a way to act, not a way to talk, and this MCU demonstrably has the
acting part.


## Is the board actually brickable? (kwboot)

**Open question, testable, and it would change §0 if it holds.** The safety model
says mtd0 is "the only recovery path short of a SOIC clip". That may be false.

The 88F6281 has a mask-ROM BootROM which, per `kwboot(1)`, "polls the UART for a
brief period of time" on every power-up, looking for a handshake that starts an
xmodem image upload. U-Boot's `kwboot` speaks it and names Kirkwood explicitly,
citing the 88F6281 functional spec chapter 24.2. If it answers on this board,
then the SoC has a recovery path that **no flash write can damage**, and the
worst case drops from "desolder the SPI chip" to "plug in the serial cable".

```sh
# board must be OFF; kwboot has to be listening before the BootROM polls
/src/kernel/kwboot-test.sh handshake     # then power on
/src/kernel/kwboot-test.sh debug         # BootROM's own console; ? for help
```

The script stops the serial logger first (gotcha 1 - two readers split the
bytes and the handshake silently never matches) and restarts it on exit.

**This writes nothing.** It sends the handshake and uploads no image, so the
worst case is the BootROM waiting for a transfer that never arrives, cured by a
power cycle. It cannot touch flash.

What the outcomes mean:

- `Handshake with bootrom established` — the recovery path is real. mtd0 stops
  being irreplaceable. It would still be the *cheaper* recovery, so "never
  `bubt`" stays good practice, but the catastrophic-risk tier disappears and
  experiments that were off the table become merely inconvenient.
- The normal `U-Boot 1.1.4` banner scrolls past — the BootROM did not answer.
  Worth retrying: the polling window is short and the handshake has to overlap
  it. Only after several attempts is a negative meaningful.

Caveat worth stating: even a working kwboot only helps if a serial console is
attached, which on this bench it always is - but it is not a recovery path for
a box in a cupboard.

## Gotchas that have cost real time

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

4. **Warm reboot does not work yet** — but DSM reboots this board, so the
   mechanism exists and is merely unknown (PORTING.md §3.3). Neither Linux nor U-Boot 2026.07 can
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

**`grep` the serial log with `-a`.** `logs/serial.log` contains raw console
bytes, so grep classifies it as binary and prints *nothing* rather than the
matching lines — it does not error, it just silently finds nothing. This has
already caused two wrong conclusions in this project ("the mirror is not
working", when it was). Always:

```sh
grep -a MCU-SEND /src/kernel/logs/serial.log | tr -d '\r'
```

Every character sent to the MCU by `ds410j-bench.sh mcu send` is mirrored to the
serial console and so ends up here, prefixed `MCU-SEND`. That matters because the
on-box log (`/root/mcu-map.txt`) is on a **tmpfs** and dies at every reboot — it
is what lost the record of whatever was sent around the time the box started
powering on at AC restore (PORTING.md §3.3). The host-side serial log is the only
persistent record this bench has.


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
... OK`, then `## Loading Ramdisk Image at f8280000` naming the ramdisk stub with its
own `Verifying Checksum ... OK`, then the U-Boot 2026.07 banner.

## Iterating on U-Boot

`nix-build /src/uboot` produces a raw `u-boot.bin`. Two ways to run it:

- **`go`** takes the raw binary. Fast, but it inherits the running U-Boot's state -
  in particular **already-powered USB hub ports**, so it cannot reproduce cold-boot
  USB behaviour (PORTING.md §5.2). Never validate a USB fix this way.
- **`bootm`** needs a uImage wrapper, and is the path the flashed payload actually
  takes. Use this for anything you intend to flash.

Wrapping for `bootm` - note `mkimage` cannot run on `/src` (gotcha 5):

```sh
nix-build /src/uboot -o /src/uboot/result
cp -fL /src/uboot/result/u-boot.bin /tmp/ub.bin
mkimage -A arm -O linux -T kernel -C none -a 0x02000000 -e 0x02000000         -n 'U-Boot 2026.07 DS410j' -d /tmp/ub.bin /tmp/uImage-ub
cp /tmp/ub.bin /tmp/uImage-ub /var/lib/tftpboot/
```

`-T kernel` is not cosmetic: `IH_TYPE_STANDALONE` does not work here, and
`-a`/`-e` must both be `0x02000000` to match `CONFIG_TEXT_BASE` (PORTING.md §4).
`mkimage` is at `$(nix-build '<nixpkgs>' -A ubootTools --no-out-link)/bin/mkimage`.

For USB or hub problems there is a diagnostic build that defines `DEBUG` in the USB
core, so `usb start` prints per-port status and every control transfer:

```sh
nix-build /src/uboot --arg debugUsb true -o /src/uboot/result-debug
```

It is far too verbose to flash, and remember that its printfs supply timing that a
normal build does not - a fix that only works in the debug build is not a fix.

### Flashing a new U-Boot

Rehearse with `bootm` on a **cold** boot first, then, from the resulting U-Boot:

```
sf probe
tftpboot 0x03000000 uImage-ub          # then crc32 0x03000000 <len> and compare
sf protect unlock 0 0x400000
sf erase 0x80000 0x200000
sf write 0x03000000 0x80000 <len>
sf read 0x03800000 0x80000 <len>       # crc32 again, must match
sf protect lock 0 0x400000
sf erase 0x3F0000 0x10000              # MUST fail: "flash area is locked"
```

Then re-read mtd0/mtd2/mtd3/mtd5 and compare against PORTING.md §2. Predict every
checksum offline *before* writing; a matching whole-chip crc32 is what proves
nothing else moved.

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
sha256sum "$IMG"          # 7df4f9fd2273d904975f84bdb6652af76b4f8e4f41092da9babbc3bdba55de0d
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

## Decisions already settled

All of these were open before the first flash write and are now closed; the reasoning
lives in `PORTING.md` and is not repeated here.

- **Payload type and load address** - `IH_TYPE_KERNEL` at `0x02000000`, never
  `IH_TYPE_STANDALONE` (§4).
- **Cache state at handover** - `cleanup_before_linux()` on the way out plus
  `CONFIG_SKIP_LOWLEVEL_INIT_ONLY` on the way in (§5.1). Still rehearse with `bootm`,
  not `go`.
- **Losing stock DSM** - accepted by project decision; the two-stage chain is what is
  protected, not the stock OS (CLAUDE.md, "What we are protecting").
- **mtd2 is load-bearing for our own chain** - it now holds our 685-byte ramdisk stub
  rather than Synology's `rd.gz`, and must never be merely blank (§4).

## Risk ranking of the candidate writes

| Target | Risk | Recovery if it goes wrong |
|---|---|---|
| **mtd4** (env, 0x3D0000) | **lowest** - the stock loader provably never reads it (PORTING.md §5.4: built with `CFG_ENV_IS_NOWHERE`), so a bad env can only affect stage 2 | Re-flash 128 KB, or erase it so U-Boot falls back to its built-in defaults |
| **mtd1** (our U-Boot, 0x80000) | **low** - stock loader at offset 0 is untouched and still TFTP-boots | Re-flash over TFTP+Linux via the stock loader; the chain's stage 1 is what makes this safe |
| **mtd2** (ramdisk arg, 0x280000) | **medium** - a *blank* mtd2 boot-loops instead of dropping to a prompt | Interrupt autoboot with `spam.sh` (bootdelay=3 still applies on each loop), then TFTP. `uboot/out/stub-ramdisk.uimg` is regenerable from `uboot/default.nix` |
| **mtd0** (bootloader, 0x0) | **HIGH - do not** | External SPI programmer only (desolder). Full-chip image is `ds410j-flash-full-4MB.bin` |

Prefer mtd4, then mtd1. `PORTING.md` §4 has the reasoning; mtd0 is a last
resort and the plan should not require it.
