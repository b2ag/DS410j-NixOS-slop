# Modern U-Boot for the DS410j, built to be chainloaded from the stock
# Marvell U-Boot 1.1.4 (PORTING.md section 5 phase 2).
#
# ds109 is the closest in-tree Synology Kirkwood 88F6281 target. Per PORTING.md
# section 5 the U-Boot DTB is deliberately NOT coupled to the Linux DTB - U-Boot
# only cares about UART, SPI, GbE and USB.
{ pkgs ? import <nixpkgs> { }
, # Where the chainloaded image is linked to run. MUST NOT be 0x600000: that is
  # where the running stock U-Boot lives (verified from its banner,
  # "U-Boot code: 00600000 -> 0067FFF0"), so linking there would make the TFTP
  # write clobber the loader that is doing the loading.
  textBase ? "0x02000000"
  # Diagnostic image: turns on the debug() prints in the USB core and hub code by
  # defining DEBUG in those translation units (U-Boot's debug() compiles to
  # nothing unless DEBUG is defined in the file itself). Very verbose - for
  # TFTP + `go` iteration only, never for flashing.
, debugUsb ? false
}:

let
  cross = pkgs.pkgsCross.armv5tel-multiplatform;
in
cross.buildUBoot {
  defconfig = "ds109_defconfig";

  # The ds109 default environment has no ethaddr, and the ds109 DTB carries no
  # local-mac-address. U-Boot's eth uclass therefore finds no MAC at first probe
  # and fails the device; every retry then re-enters mvgbe_probe(), which tries
  # to mdio_register() a bus named after the device and trips the duplicate-name
  # check ("non unique device name 'ethernet-controller@72000'"). Setting ethaddr
  # from the U-Boot shell is too late - the device has already failed. Bake the
  # real MAC (from the vendor partition, PORTING.md section 7.2) into the
  # built-in default env so it is present on the very first probe.
  preConfigure = ''
    substituteInPlace include/configs/ds109.h \
      --replace-fail '"x_bootcmd_ethernet=ping 192.168.1.2\0"' \
                     '"ethaddr=00:11:32:02:f9:a6\0" "kernel_addr_r=0x00800000\0" "fdt_addr_r=0x02000000\0" "ramdisk_addr_r=0x02100000\0" "scriptaddr=0x01c00000\0" "pxefile_addr_r=0x01d00000\0" "bootm_size=0x08000000\0" "x_bootcmd_ethernet=ping 192.168.1.2\0"'
    # THE fix for "unable to get device descriptor (error=-1)" on this board.
    #
    # The DS410j's ports are behind a GL850G hub. common/usb_hub.c's
    # usb_hub_port_connect_change() goes straight from noticing the connect to
    # usb_hub_port_reset() with no settle delay, but USB 2.0 section 7.1.7.3
    # (TATTDB) requires at least 100 ms after connect detection before reset, so
    # the device's power can stabilise and the connection can debounce. Linux
    # does this (hub_port_debounce); U-Boot does not.
    #
    # Without it the reset lands too early, the high-speed chirp handshake does
    # not settle, and the following control transfer fails - the stick is simply
    # never enumerated. This was masked in a DEBUG build purely because the
    # debug() printfs at 115200 baud happen to insert the missing delay, which is
    # what made it look like a flaky race rather than a missing wait.
    substituteInPlace common/usb_hub.c \
      --replace-fail 'ret = usb_hub_port_reset(dev, port, &portstatus);' \
                     'mdelay(200); ret = usb_hub_port_reset(dev, port, &portstatus);'

    # ...and the reason cold boot still failed after that fix. U-Boot reads a
    # hub port's status only max(100, pgood_delay) ms after switching port power
    # on. On a cold boot that is far too early for this hub+stick: the port
    # reports a *connection-change* event with the CONNECTION bit still clear,
    # i.e. the normal bounce as VBUS rises. Captured from the board:
    #
    #   PowerOn : port 1 returns 0
    #   devnum=2 poweron: query_delay=100 connect_timeout=5100
    #   Port 1 Status 100 Change 1        <- C_CONNECTION set, CONNECTION clear
    #   devnum=2 port=1: USB dev found
    #   usb_disconnect(&hub->children[port]);
    #
    # usb_scan_port() only keeps waiting when NEITHER bit is set, so a change
    # with no connection sends it into usb_hub_port_connect_change(), which sees
    # CONNECTION == 0, treats it as a disconnect, returns -ENOTCONN, and the port
    # is dropped from the scan list for good. Nothing rescans it. That is why
    # raising CONFIG_USB_HUB_DEBOUNCE_TIMEOUT changed nothing - the port was gone
    # before any debouncing could happen - and why a DEBUG build "worked": its
    # printfs delayed that first read past the bounce.
    #
    # A working port reads 0x101 (POWER|CONNECTION); the failing one reads 0x100.
    substituteInPlace common/usb_hub.c \
      --replace-fail 'hub->query_delay = get_timer(0) + max(100, (int)pgood_delay);' \
                     'hub->query_delay = get_timer(0) + max(1000, (int)pgood_delay);'

    # SAFETY: keep the fans running across the handover.
    #
    # The DS410j's fan is a 3-bit GPIO speed select on GPIO0 pins 15/16/17
    # (kirkwood-synology.dtsi, gpio-fan-150-15-18), where 0 means OFF and the
    # speed-map runs 1=2200 .. 7=4200 rpm. The ds109 board file's MPP table
    # reconfigures MPP15/16/17 as GPIO - the DS109's own fan is on 32-35, which
    # is the other DTS node - and leaves them low, i.e. speed 0. Observed on the
    # bench: fans spin at the stock "Marvell>>" prompt and stop as soon as our
    # U-Boot takes over.
    #
    # Linux does NOT recover this. kirkwood-ds409.dts sets gpio-fan-150-15-18 to
    # status = "okay", but the driver fails to probe:
    #   gpio-fan gpio-fan-150-15-18: setup of GPIO alarm failed: -524
    # so the pins keep whatever U-Boot left. M3 never saw it because that kernel
    # was booted straight from the stock loader, which leaves the fans running -
    # PORTING.md 10.3's "the fans run from hardware default" is true only for the
    # path we do not ship.
    #
    # So stage 2 has to set them itself. 3 = 3300 rpm (bit0=GPIO15, bit1=GPIO16,
    # bit2=GPIO17); change DS410J_FAN_SPEED for more or less. Note the encoding
    # is not monotonic - 4 is 3000 rpm, below 3's 3300.
    substituteInPlace board/Synology/ds109/ds109.c \
      --replace-fail '#include "ds109.h"' \
                     '#include "ds109.h"
#include <asm/arch/gpio.h>
#define DS410J_FAN_SPEED 3
#define DS410J_FAN_SHIFT 15' \
      --replace-fail 'gd->bd->bi_boot_params = mvebu_sdram_bar(0) + 0x100;' \
                     'gd->bd->bi_boot_params = mvebu_sdram_bar(0) + 0x100;

	/* DS410j: pin the fan to a safe speed - see uboot/default.nix.
	 * The kw_gpio_* helpers are only declared in mach/gpio.h, never
	 * implemented in this tree, so drive the registers directly. On Kirkwood
	 * a 0 bit in GPIO_IO_CONF enables the output. Set the data first, then
	 * enable the drivers, so the pins never glitch through 0 (= fan off).
	 */
	{
		u32 mask = 7u << DS410J_FAN_SHIFT;
		u32 out  = readl(GPIO_OUT(DS410J_FAN_SHIFT));
		u32 conf = readl(GPIO_IO_CONF(DS410J_FAN_SHIFT));

		out = (out & ~mask) | ((DS410J_FAN_SPEED & 7u) << DS410J_FAN_SHIFT);
		writel(out, GPIO_OUT(DS410J_FAN_SHIFT));
		writel(conf & ~mask, GPIO_IO_CONF(DS410J_FAN_SHIFT));
	}'

    # The delay above is necessary but NOT sufficient, because the real defect is
    # the guard itself. usb_scan_port() only keeps waiting when NEITHER the
    # change bit nor the connection bit is set:
    #
    #   if (!(portchange & USB_PORT_STAT_C_CONNECTION) &&
    #       !(portstatus & USB_PORT_STAT_CONNECTION)) { ...keep waiting... }
    #
    # so a *latched* C_CONNECTION with CONNECTION clear - exactly what a VBUS
    # ramp produces - falls through and is acted on as a device, then rejected as
    # a disconnect, and the port is dropped for good. Delaying the read only
    # changes when we sample a sticky bit; it cannot fix acting on a port that is
    # not connected.
    #
    # Require the CONNECTION bit. This keeps the upstream special case the
    # comment there describes ("hub reports no connection change but a device is
    # connected, CCS set but CSC not") working, since that case has CONNECTION
    # set and so still proceeds. What changes is that a change-without-connection
    # now stays in the scan list and is polled until connect_timeout, which is
    # what makes CONFIG_USB_HUB_DEBOUNCE_TIMEOUT meaningful at last.
    substituteInPlace common/usb_hub.c \
      --replace-fail 'if (!(portchange & USB_PORT_STAT_C_CONNECTION) &&' \
                     'if (/* DS410j: require CONNECTION, not a latched change */ 1 &&'
  '' + pkgs.lib.optionalString debugUsb ''
    for f in common/usb.c common/usb_hub.c common/usb_storage.c; do
      [ -f "$f" ] && sed -i '1i #define DEBUG 1' "$f"
    done
  '';
  extraMeta.platforms = [ "armv5tel-linux" ];

  # u-boot.bin, not u-boot.kwb: the .kwb wrapper carries a DDR register-init list
  # for the SoC BootROM. DRAM is already up when we are chainloaded.
  filesToInstall = [ "u-boot.bin" "u-boot" "u-boot.map" ".config" ];

  extraConfig = ''
    CONFIG_TEXT_BASE=${textBase}

    # ds109_defconfig puts the pre-relocation stack in Kirkwood internal SRAM
    # (0xc8012000). That window is mapped by lowlevel_init / the BootROM, which
    # this config skips - so when chainloaded the stack can land on unmapped
    # memory and fault before any console exists. Put it in known-good DRAM,
    # above the stock loader's reserved low 8 MB and below our load address.
    CONFIG_HAS_CUSTOM_SYS_INIT_SP_ADDR=y
    CONFIG_CUSTOM_SYS_INIT_SP_ADDR=0x01f00000

    # Print from the very first instructions, long before the DM console is up.
    # Without this an early fault is completely silent and undiagnosable.
    # Kirkwood UART0 is at 0xf1012000, reg-shift 2, clocked from TCLK = 200 MHz
    # (from the stock loader banner: "SysClock = 400Mhz , TClock = 200Mhz").
    CONFIG_DEBUG_UART=y
    CONFIG_DEBUG_UART_NS16550=y
    CONFIG_DEBUG_UART_BASE=0xf1012000
    CONFIG_DEBUG_UART_CLOCK=200000000
    CONFIG_DEBUG_UART_SHIFT=2
    CONFIG_DEBUG_UART_ANNOUNCE=y

    # Chainloaded: DRAM and the CPU are already initialised by the stock loader,
    # so lowlevel_init (pll/mux/DDR) must NOT re-run. But SKIP_LOWLEVEL_INIT
    # skips the *whole* of cpu_init_crit, which is too blunt: it also skips the
    # CP15 init, so we would inherit the stock loader's cache/MMU state wholesale
    # (PORTING.md section 10.5's "cache state at handoff" hazard - the one that
    # actually killed the toy standalone payload). The stock env shows L2 enabled
    # (disL2Cache=no, setL2CacheWT=yes) with both prefetchers on, so this is not
    # theoretical.
    #
    # SKIP_LOWLEVEL_INIT_ONLY is the correct knob for a chainloaded payload: in
    # arch/arm/cpu/arm926ejs/start.S it still runs cpu_init_crit (test-and-clean
    # the D-cache, invalidate TLB + I-cache, disable MMU and D-cache, re-enable
    # I-cache) and skips only the bl to lowlevel_init. cpu_init_crit touches no
    # stack, so it is safe this early. The two symbols are independent bools
    # (arch/Kconfig), hence explicitly clearing the one the defconfig sets.
    #
    # Caveat this does NOT fix: the handful of instructions fetched at TEXT_BASE
    # *before* cpu_init_crit runs still depend on the loader's memmove being
    # visible to the instruction fetch. That is unfixable from the payload side
    # and is what the bootm rehearsal in RAM is for.
    # CONFIG_SKIP_LOWLEVEL_INIT is not set
    CONFIG_SKIP_LOWLEVEL_INIT_ONLY=y

    # Raising this alone did nothing, because the port was dropped from the scan
    # list before any debouncing could happen. With the usb_scan_port guard fixed
    # (see preConfigure) the port now stays in the list and this is the actual
    # budget for the stick to report a connection after port power comes up.
    # Total window is query_delay (1000) + this. Only paid when a port never
    # connects, i.e. on a boot with nothing plugged in.
    CONFIG_USB_HUB_DEBOUNCE_TIMEOUT=3000

    # NixOS's initrd is a raw gzipped cpio, not a uImage-wrapped ramdisk. Without
    # this, the extlinux path loads the kernel fine and then dies with
    #   Wrong Ramdisk Image Format / Ramdisk image is corrupt or invalid
    # because U-Boot will only accept a legacy uImage ramdisk and rejects the
    # "addr:size" raw form that boot/pxe_utils.c hands it.
    CONFIG_SUPPORT_RAW_INITRD=y

    # useful for the eventual /boot-on-USB path
    CONFIG_CMD_USB=y
    CONFIG_USB_STORAGE=y
    CONFIG_CMD_FAT=y
    CONFIG_CMD_EXT2=y
    CONFIG_CMD_EXT4=y
    CONFIG_FS_EXT4=y
    CONFIG_CMD_FS_GENERIC=y
    CONFIG_CMD_BOOTZ=y
    CONFIG_CMD_PART=y
    CONFIG_DOS_PARTITION=y
    CONFIG_EFI_PARTITION=y
  '';
}
