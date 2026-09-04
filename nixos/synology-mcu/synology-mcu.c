// SPDX-License-Identifier: GPL-2.0
/*
 * Synology DS410j board microcontroller, on UART1 (serial@12100, 9600 8N1).
 *
 * The DS410j's front-panel buttons are NOT GPIOs. Fourteen GPIO candidates were
 * searched before that was established (PORTING.md 7.1). The board has a small
 * microcontroller on UART1 which owns the front-panel power and status lamps,
 * the buzzer and the power rail, and which reports the buttons as single ASCII
 * bytes. This driver binds that UART as a serdev client and turns the MCU's
 * event bytes into input events, so logind applies the ordinary power-key
 * policy and no userspace daemon has to sit on a tty.
 *
 * THE ONE THING TO KNOW ABOUT THE POWER BUTTON: the MCU only reports a press
 * once the button has been held for about four seconds. A short press puts
 * nothing on the wire at all. This is why the button looked dead for so long -
 * every test press was a tap, the UART honestly reported rx:0, and three
 * separate theories (a bad receive pinmux, an unheld port, a missing "arming"
 * command) were chased and disproved before the real answer turned up. The
 * threshold is in MCU firmware; there is no short-press event to react to and
 * no way to add one.
 *
 * POWER OFF is ours too. kirkwood-synology.dtsi declares a separate
 * "synology,power-off" node over the same registers for mainline's
 * drivers/power/reset/qnap-poweroff.c, and two nodes at 12100 is what makes dtc
 * warn about a duplicate unit address. kirkwood-ds410j.dts deletes that node, so
 * this driver has to provide the power-off handler - if it does not load, the
 * box has no way to cut its own power.
 *
 * The handler does NOT go through serdev. By the time a power-off handler runs,
 * device_shutdown() has already been round the tree and the call may happen with
 * interrupts disabled, so the tty layer is not available and nothing may sleep.
 * It therefore reprograms the UART from scratch through a direct mapping and
 * writes the byte itself - the same approach, and the same register sequence, as
 * qnap-poweroff.c. of_iomap() on the parent's reg is deliberate: it maps without
 * requesting the region, so it does not collide with the 8250 that owns the port
 * (which is exactly how the mainline driver coexists with it today).
 *
 * What this driver deliberately does NOT do:
 *
 *   Reboot.  Warm reboot is not solved on this board YET - DSM offers a reboot
 *   and it works, so a mechanism exists and we have not found it (PORTING.md
 *   3.3). Whatever it turns out to be, this driver is the natural home for it:
 *   the UART mapping and a sys-off handler are already here, so a restart
 *   handler would be a few lines once the command is known. Until then 0x61
 *   becomes KEY_RESTART and userspace decides.
 *
 *   Blink.  The lamps are exposed as plain on/off LED class devices using
 *   brightness_set_blocking, which is the callback that is guaranteed to be
 *   allowed to sleep - and talking to a 9600 baud UART sleeps. The MCU's
 *   blinking states are still reachable through the debugfs send file below,
 *   which is how nixos/ds410j-mcu.sh drives them.
 *
 * Binding: "synology,ds410j-mcu" is a local compatible, not an upstream one.
 */

#include <linux/clk.h>
#include <linux/ctype.h>
#include <linux/debugfs.h>
#include <linux/input.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/leds.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/reboot.h>
#include <linux/seq_file.h>
#include <linux/serdev.h>
#include <linux/serial_reg.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define DRV_NAME	"synology-mcu"
#define MCU_BAUD	9600

/*
 * ---------------------------------------------------------------------------
 * The protocol
 * ---------------------------------------------------------------------------
 *
 * Single ASCII characters, both directions, no framing and no handshake. That
 * last point was tested rather than assumed: with a live DSM scemd that was
 * free to reply, a button press produced exactly one byte from the MCU and
 * nothing further, and what scemd wrote back a second later was just the
 * shutdown indication (power LED blinking, long beep).
 *
 * Two independent sources agree on the table, and where they overlap they
 * agree with each other:
 *
 *   [MEASURED]  verified on this DS410j, or read out of DSM's own scemd binary
 *               (the 5-way dispatch in event_microp.c, and its log strings).
 *
 *   [DS207]     from a third-party write-up of Synology's UART2_CMD_* enum at
 *               https://smallhacks.wordpress.com/2012/04/17/working-with-
 *               synology-hardware-devsynobios-and-devttys1/
 *               That author's hardware appears to be a DS207, NOT a DS410j.
 *               Every code we independently measured matches it, which is good
 *               corroboration - but nothing above 0x3b has been tested here and
 *               some of it plainly does not apply (this box has no USB LED, no
 *               10G LAN LED and no mirror LED). Treat as a lead, not as fact.
 *
 * Host -> MCU
 *
 *   0x31 '1'  SHUTDOWN               [MEASURED] cuts power. This driver's
 *                                    power-off handler sends it; the debugfs
 *                                    send file refuses it by default.
 *   0x32 '2'  BUZZER_SHORT           [MEASURED]
 *   0x33 '3'  BUZZER_LONG            [MEASURED]
 *   0x34 '4'  LED_POWER_ON           [MEASURED] steady
 *   0x35 '5'  LED_POWER_BLINK        [MEASURED]
 *   0x36 '6'  LED_POWER_OFF          [MEASURED]
 *   0x37 '7'  LED_HD_OFF             [MEASURED] "HD" = the status lamp
 *   0x38 '8'  LED_HD_GS              [MEASURED] green solid
 *   0x39 '9'  LED_HD_GB              [MEASURED] green blinking
 *   0x3a ':'  LED_HD_AS              [MEASURED] amber/orange solid
 *   0x3b ';'  LED_HD_AB              [MEASURED] amber/orange blinking
 *   0x3d '='  LED_HD_BREATH          [DS207]
 *   0x40 '@'  LED_USB_ON             [DS207]  no USB LED on this box
 *   0x41 'A'  LED_USB_BLINK          [DS207]
 *   0x42 'B'  LED_USB_OFF            [DS207]
 *   0x4a 'J'  LED_10G_LAN_ON         [DS207]  n/a here
 *   0x4b 'K'  LED_10G_LAN_OFF        [DS207]  n/a here
 *   0x50 'P'  LED_MIRROR_OFF         [DS207]  n/a here
 *   0x51 'Q'  LED_MIRROR_GS          [DS207]
 *   0x52 'R'  LED_MIRROR_GS/AS       [DS207]  also listed as GET_UNIQUE (x86)
 *   0x53 'S'  LED_MIRROR_AS          [DS207]
 *   0x54 'T'  LED_MIRROR_AB          [DS207]
 *   0x55 'U'  TOGGLE_FAN_RPS_REPORT  [DS207]  implies the MCU can report fan
 *                                    RPM - a tacho this board was thought not
 *                                    to have. Untested, and interesting.
 *   0x56 'V'  SET_PWM_DUTY           [DS207]  our fan is a 3-bit GPIO speed
 *   0x57 'W'  SET_PWM_FREQ           [DS207]  select, so probably n/a
 *   0x70 'p'  RCPOWEROFF             [DS207]  DANGEROUS - cuts power
 *   0x71 'q'  RCPOWERON              [DS207]
 *   0x72 'r'  DISABLE_SCHEDULE_POWERON [DS207] a lead for PORTING.md 3.3,
 *   0x73 's'  ENABLE_SCHEDULE_POWERON  [DS207] power-on after AC loss
 *   0x74 't'  DISABLE_FANCHECK       [MEASURED in use] DSM sends this on its
 *                                    shutdown path, so the MCU does not raise a
 *                                    fan alarm as the fan spins down. Its
 *                                    meaning is [DS207].
 *   0x75 'u'  ENABLE_FANCHECK        [DS207]
 *   "EC0"     DISABLE_CPUFANCHECK    [DS207]  multi-character, unlike the rest
 *   "EC1"     ENABLE_CPUFANCHECK     [DS207]
 *   0x6c 'l'  WOL_ENABLE             [DS207]  noted as not working on a DS207
 *
 * MCU -> host  (the five bytes DSM's scemd dispatches on, and nothing else)
 *
 *   0x30 '0'  BUTTON_POWER    [MEASURED] held ~4 s; a short press sends nothing
 *   0x60 '`'  BUTTON_USB      [MEASURED] scemd logs "USBcopy/Mute button
 *                             pressed, Model error?" for it. The DS410j has no
 *                             USB-copy button (synoinfo.conf says usbcopy="no"),
 *                             so this should never arrive here.
 *   0x61 'a'  BUTTON_RESET    [MEASURED] rear reset button
 *   0x66 'f'  FAN_FAILURE     [MEASURED in scemd's dispatch; meaning DS207,
 *                             corroborated by scemd's fan strings]
 *   0x67 'g'  CPUFAN_FAILURE  ditto - and scemd contains the literal string
 *                             "Fan stop [UART2_CMD_CPUFAN_FAILURE]", which is
 *                             what named this whole enum for us.
 *
 * Fan failure has NOT been reproduced on this board: disconnecting the fans
 * produced no MCU traffic on two attempts. Either fan checking is off by
 * default (0x75 ENABLE_FANCHECK is the thing to try, via the debugfs send file)
 * or this model's MCU does not monitor the fan at all. Note the stock Marvell
 * loader prints "Fan Status: Good" in its banner, so something on this board
 * does read a fan sensor.
 */

/* host -> MCU, only the ones this driver itself emits */
#define MCU_CMD_SHUTDOWN	'1'
#define MCU_CMD_LED_POWER_ON	'4'
#define MCU_CMD_LED_POWER_OFF	'6'
#define MCU_CMD_LED_HD_OFF	'7'
#define MCU_CMD_LED_HD_GREEN	'8'
#define MCU_CMD_LED_HD_AMBER	':'

/* MCU -> host */
#define MCU_EVT_BUTTON_POWER	'0'
#define MCU_EVT_BUTTON_USB	'`'
#define MCU_EVT_BUTTON_RESET	'a'
#define MCU_EVT_FAN_FAILURE	'f'
#define MCU_EVT_CPUFAN_FAILURE	'g'

/* bytes that cut power, refused unless the debugfs caller really means it */
static bool allow_dangerous;
module_param(allow_dangerous, bool, 0644);
MODULE_PARM_DESC(allow_dangerous,
		 "permit '1' and 'p' (power off) through the debugfs send file");

#define RX_RING_LEN 64

struct mcu_rx_entry {
	u64	ns;
	u8	byte;
};

enum status_colour {
	STATUS_OFF = 0,
	STATUS_GREEN,
	STATUS_AMBER,
};

struct syno_mcu {
	struct serdev_device	*serdev;
	struct device		*dev;
	struct input_dev	*input;

	struct led_classdev	power_led;
	struct led_classdev	status_green;
	struct led_classdev	status_amber;

	/* serialises writes to the MCU, and the status-lamp arbitration */
	struct mutex		lock;
	enum status_colour	status;

	/* direct UART mapping, used only by the power-off handler */
	void __iomem		*uart;
	unsigned int		divisor;

	spinlock_t		rx_lock;
	struct mcu_rx_entry	rx_ring[RX_RING_LEN];
	unsigned int		rx_head;	/* next slot to write */
	unsigned int		rx_total;	/* bytes ever received */

	u64			n_power;
	u64			n_reset;
	u64			n_usb;
	u64			n_fan;
	u64			n_cpufan;
	u64			n_unknown;

	struct dentry		*debugfs;
};

static const char *mcu_event_name(u8 b)
{
	switch (b) {
	case MCU_EVT_BUTTON_POWER:	return "BUTTON_POWER (held ~4s)";
	case MCU_EVT_BUTTON_USB:	return "BUTTON_USB";
	case MCU_EVT_BUTTON_RESET:	return "BUTTON_RESET";
	case MCU_EVT_FAN_FAILURE:	return "FAN_FAILURE";
	case MCU_EVT_CPUFAN_FAILURE:	return "CPUFAN_FAILURE";
	default:			return "unknown";
	}
}

/* ------------------------------------------------------------------ tx --- */

static int mcu_send_locked(struct syno_mcu *mcu, u8 byte)
{
	int ret;

	ret = serdev_device_write(mcu->serdev, &byte, 1, MAX_SCHEDULE_TIMEOUT);
	if (ret < 0) {
		dev_err(mcu->dev, "write of 0x%02x '%c' failed: %d\n",
			byte, isprint(byte) ? byte : '.', ret);
		return ret;
	}
	serdev_device_wait_until_sent(mcu->serdev, 0);
	return 0;
}

static int mcu_send(struct syno_mcu *mcu, u8 byte)
{
	int ret;

	mutex_lock(&mcu->lock);
	ret = mcu_send_locked(mcu, byte);
	mutex_unlock(&mcu->lock);
	return ret;
}

/* ------------------------------------------------------------------ rx --- */

static void mcu_rx_record(struct syno_mcu *mcu, u8 byte)
{
	unsigned long flags;

	spin_lock_irqsave(&mcu->rx_lock, flags);
	mcu->rx_ring[mcu->rx_head].ns = ktime_get_ns();
	mcu->rx_ring[mcu->rx_head].byte = byte;
	mcu->rx_head = (mcu->rx_head + 1) % RX_RING_LEN;
	mcu->rx_total++;
	spin_unlock_irqrestore(&mcu->rx_lock, flags);
}

static void mcu_key(struct syno_mcu *mcu, unsigned int code)
{
	/*
	 * The MCU reports an event, not a button state: there is no release
	 * byte and nothing is sent while the button is held. So synthesise a
	 * press and an immediate release, which is what logind expects.
	 */
	input_report_key(mcu->input, code, 1);
	input_sync(mcu->input);
	input_report_key(mcu->input, code, 0);
	input_sync(mcu->input);
}

static void mcu_handle(struct syno_mcu *mcu, u8 byte)
{
	mcu_rx_record(mcu, byte);

	switch (byte) {
	case MCU_EVT_BUTTON_POWER:
		mcu->n_power++;
		dev_info(mcu->dev, "power button\n");
		mcu_key(mcu, KEY_POWER);
		break;
	case MCU_EVT_BUTTON_RESET:
		mcu->n_reset++;
		dev_info(mcu->dev, "reset button\n");
		/*
		 * KEY_RESTART, not a reboot: warm reboot does not work on this
		 * SoC (PORTING.md 3.3), so whatever userspace policy picks up
		 * this key is where the decision belongs, not here.
		 */
		mcu_key(mcu, KEY_RESTART);
		break;
	case MCU_EVT_BUTTON_USB:
		mcu->n_usb++;
		dev_info(mcu->dev, "USB-copy button (this model has none)\n");
		break;
	case MCU_EVT_FAN_FAILURE:
		mcu->n_fan++;
		dev_crit(mcu->dev, "MCU reports FAN FAILURE\n");
		break;
	case MCU_EVT_CPUFAN_FAILURE:
		mcu->n_cpufan++;
		dev_crit(mcu->dev, "MCU reports CPU FAN FAILURE\n");
		break;
	default:
		mcu->n_unknown++;
		dev_warn(mcu->dev, "unknown MCU byte 0x%02x '%c'\n",
			 byte, isprint(byte) ? byte : '.');
		break;
	}
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
static size_t mcu_receive_buf(struct serdev_device *serdev,
			      const u8 *data, size_t count)
#else
static int mcu_receive_buf(struct serdev_device *serdev,
			   const unsigned char *data, size_t count)
#endif
{
	struct syno_mcu *mcu = serdev_device_get_drvdata(serdev);
	size_t i;

	for (i = 0; i < count; i++)
		mcu_handle(mcu, data[i]);

	return count;
}

static const struct serdev_device_ops mcu_serdev_ops = {
	.receive_buf	= mcu_receive_buf,
	.write_wakeup	= serdev_device_write_wakeup,
};

/* ---------------------------------------------------------------- leds --- */

static int mcu_power_led_set(struct led_classdev *cdev,
			     enum led_brightness value)
{
	struct syno_mcu *mcu = container_of(cdev, struct syno_mcu, power_led);

	return mcu_send(mcu, value ? MCU_CMD_LED_POWER_ON : MCU_CMD_LED_POWER_OFF);
}

/*
 * One lamp, two colours, one command set: the MCU has a single "HD" status
 * light and a command per (colour, state). Two LED class devices are the
 * natural fit for userspace, so they have to be kept mutually exclusive here -
 * exactly the same constraint the bay LEDs have (CLAUDE.md), for the same
 * reason. Lighting one colour implicitly extinguishes the other, so the other
 * class device's cached brightness is corrected to match the hardware.
 */
static int mcu_status_set(struct syno_mcu *mcu, enum status_colour want,
			  enum led_brightness value)
{
	struct led_classdev *other;
	enum status_colour now;
	u8 cmd;
	int ret;

	mutex_lock(&mcu->lock);

	if (value) {
		now = want;
		cmd = (want == STATUS_GREEN) ? MCU_CMD_LED_HD_GREEN
					     : MCU_CMD_LED_HD_AMBER;
	} else if (mcu->status == want) {
		now = STATUS_OFF;
		cmd = MCU_CMD_LED_HD_OFF;
	} else {
		/* turning off a colour that is not lit: nothing to do */
		mutex_unlock(&mcu->lock);
		return 0;
	}

	ret = mcu_send_locked(mcu, cmd);
	if (!ret) {
		mcu->status = now;
		other = (want == STATUS_GREEN) ? &mcu->status_amber
					       : &mcu->status_green;
		if (value)
			other->brightness = LED_OFF;
	}

	mutex_unlock(&mcu->lock);
	return ret;
}

static int mcu_status_green_set(struct led_classdev *cdev,
				enum led_brightness value)
{
	struct syno_mcu *mcu = container_of(cdev, struct syno_mcu, status_green);

	return mcu_status_set(mcu, STATUS_GREEN, value);
}

static int mcu_status_amber_set(struct led_classdev *cdev,
				enum led_brightness value)
{
	struct syno_mcu *mcu = container_of(cdev, struct syno_mcu, status_amber);

	return mcu_status_set(mcu, STATUS_AMBER, value);
}

/* ------------------------------------------------------------- debugfs --- */

/*
 * The point of this interface is that the kernel module must not become the
 * thing that blocks experimenting with the MCU. The protocol is only partly
 * mapped - most of the table above is inferred from another Synology model -
 * so raw access has to stay available from userspace.
 *
 *   send      write bytes, they go to the MCU verbatim. A single trailing
 *             newline is stripped, so `echo 4 > send` does what it looks like.
 *   rx        the last RX_RING_LEN bytes the MCU sent, newest last, with
 *             timestamps. Reading does not consume them.
 *   counters  per-event totals, including unknown bytes.
 *
 * nixos/ds410j-mcu.sh writes here in preference to /dev/ttyS1, which no longer
 * exists once this driver binds the port.
 */

static ssize_t mcu_dbg_send_write(struct file *file, const char __user *ubuf,
				  size_t len, loff_t *ppos)
{
	struct syno_mcu *mcu = file->private_data;
	size_t i, n;
	u8 buf[16];
	int ret;

	if (len == 0)
		return 0;
	n = min(len, sizeof(buf));
	if (copy_from_user(buf, ubuf, n))
		return -EFAULT;

	/* a trailing newline is shell punctuation, not a command */
	if (n && buf[n - 1] == '\n')
		n--;

	for (i = 0; i < n; i++) {
		if (!allow_dangerous && (buf[i] == '1' || buf[i] == 'p')) {
			dev_warn(mcu->dev,
				 "refusing 0x%02x '%c' - powers the box off, and a soft-off DS410j needs a human at the front panel. Set the allow_dangerous module parameter if you mean it.\n",
				 buf[i], buf[i]);
			return -EPERM;
		}
	}

	for (i = 0; i < n; i++) {
		ret = mcu_send(mcu, buf[i]);
		if (ret)
			return ret;
	}

	return len;
}

static const struct file_operations mcu_dbg_send_fops = {
	.owner	= THIS_MODULE,
	.open	= simple_open,
	.write	= mcu_dbg_send_write,
	.llseek	= noop_llseek,
};

static int mcu_dbg_rx_show(struct seq_file *s, void *unused)
{
	struct syno_mcu *mcu = s->private;
	struct mcu_rx_entry *snap;
	unsigned int head, total, i, n;
	unsigned long flags;

	/* Heap, not stack: the ring is 1 KB and this kernel's stacks are 8 KB. */
	snap = kmalloc_array(RX_RING_LEN, sizeof(*snap), GFP_KERNEL);
	if (!snap)
		return -ENOMEM;

	spin_lock_irqsave(&mcu->rx_lock, flags);
	memcpy(snap, mcu->rx_ring, RX_RING_LEN * sizeof(*snap));
	head = mcu->rx_head;
	total = mcu->rx_total;
	spin_unlock_irqrestore(&mcu->rx_lock, flags);

	n = min_t(unsigned int, total, RX_RING_LEN);
	seq_printf(s, "# %u byte(s) received in total, last %u shown\n",
		   total, n);
	seq_puts(s, "#   monotonic-s   hex  char  meaning\n");

	for (i = 0; i < n; i++) {
		unsigned int idx = (head + RX_RING_LEN - n + i) % RX_RING_LEN;
		u8 b = snap[idx].byte;
		u64 sec;
		u32 nsec;

		/* div_u64_rem, not / and %: a bare 64-bit divide on 32-bit ARM
		 * pulls in __aeabi_uldivmod, which the kernel does not export. */
		sec = div_u64_rem(snap[idx].ns, NSEC_PER_SEC, &nsec);

		seq_printf(s, "%14llu.%09u  0x%02x  %c     %s\n",
			   sec, nsec, b, isprint(b) ? b : '.',
			   mcu_event_name(b));
	}

	kfree(snap);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(mcu_dbg_rx);

static int mcu_dbg_counters_show(struct seq_file *s, void *unused)
{
	struct syno_mcu *mcu = s->private;

	seq_printf(s, "power_button   %llu\n", mcu->n_power);
	seq_printf(s, "reset_button   %llu\n", mcu->n_reset);
	seq_printf(s, "usb_button     %llu\n", mcu->n_usb);
	seq_printf(s, "fan_failure    %llu\n", mcu->n_fan);
	seq_printf(s, "cpufan_failure %llu\n", mcu->n_cpufan);
	seq_printf(s, "unknown        %llu\n", mcu->n_unknown);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(mcu_dbg_counters);

/* ----------------------------------------------------------- power off --- */

/*
 * Runs late, possibly with interrupts disabled and certainly after
 * device_shutdown(), so: no serdev, no sleeping, no tty. Reprogram the port and
 * push the byte out by hand. Lifted in spirit and in register order from
 * mainline's qnap-poweroff.c, whose DT node kirkwood-ds410j.dts deletes in
 * favour of this.
 */
static int mcu_power_off(struct sys_off_data *data)
{
	struct syno_mcu *mcu = data->cb_data;
	void __iomem *base = mcu->uart;

	writel(UART_LCR_DLAB | UART_LCR_WLEN8, base + (UART_LCR << 2));
	writel(mcu->divisor & 0xff, base + (UART_DLL << 2));
	writel((mcu->divisor >> 8) & 0xff, base + (UART_DLM << 2));
	writel(UART_LCR_WLEN8, base + (UART_LCR << 2));
	writel(0, base + (UART_IER << 2));
	writel(0, base + (UART_FCR << 2));
	writel(0, base + (UART_MCR << 2));

	writel(MCU_CMD_SHUTDOWN, base + (UART_TX << 2));

	return NOTIFY_DONE;
}

static int mcu_setup_power_off(struct syno_mcu *mcu, u32 baud)
{
	struct device_node *np = mcu->dev->parent->of_node;
	unsigned long tclk;
	struct clk *clk;

	mcu->uart = of_iomap(np, 0);
	if (!mcu->uart)
		return dev_err_probe(mcu->dev, -ENOMEM,
				     "cannot map the UART for power-off\n");

	clk = of_clk_get(np, 0);
	if (IS_ERR(clk)) {
		iounmap(mcu->uart);
		return dev_err_probe(mcu->dev, PTR_ERR(clk),
				     "no UART clock, cannot compute the divisor\n");
	}
	tclk = clk_get_rate(clk);
	clk_put(clk);

	mcu->divisor = DIV_ROUND_CLOSEST(tclk, 16 * baud);

	return devm_register_sys_off_handler(mcu->dev, SYS_OFF_MODE_POWER_OFF,
					     SYS_OFF_PRIO_DEFAULT,
					     mcu_power_off, mcu);
}

/* --------------------------------------------------------------- probe --- */

static int mcu_register_leds(struct syno_mcu *mcu)
{
	int ret;

	mcu->power_led.name = "synology:blue:power";
	mcu->power_led.max_brightness = 1;
	mcu->power_led.brightness_set_blocking = mcu_power_led_set;
	mcu->power_led.default_trigger = NULL;
	ret = devm_led_classdev_register(mcu->dev, &mcu->power_led);
	if (ret)
		return dev_err_probe(mcu->dev, ret, "power LED\n");

	mcu->status_green.name = "synology:green:status";
	mcu->status_green.max_brightness = 1;
	mcu->status_green.brightness_set_blocking = mcu_status_green_set;
	ret = devm_led_classdev_register(mcu->dev, &mcu->status_green);
	if (ret)
		return dev_err_probe(mcu->dev, ret, "green status LED\n");

	mcu->status_amber.name = "synology:amber:status";
	mcu->status_amber.max_brightness = 1;
	mcu->status_amber.brightness_set_blocking = mcu_status_amber_set;
	ret = devm_led_classdev_register(mcu->dev, &mcu->status_amber);
	if (ret)
		return dev_err_probe(mcu->dev, ret, "amber status LED\n");

	return 0;
}

static int mcu_probe(struct serdev_device *serdev)
{
	struct device *dev = &serdev->dev;
	struct syno_mcu *mcu;
	u32 baud = MCU_BAUD;
	int ret;

	mcu = devm_kzalloc(dev, sizeof(*mcu), GFP_KERNEL);
	if (!mcu)
		return -ENOMEM;

	mcu->serdev = serdev;
	mcu->dev = dev;
	mutex_init(&mcu->lock);
	spin_lock_init(&mcu->rx_lock);
	serdev_device_set_drvdata(serdev, mcu);
	serdev_device_set_client_ops(serdev, &mcu_serdev_ops);

	ret = devm_serdev_device_open(dev, serdev);
	if (ret)
		return dev_err_probe(dev, ret, "cannot open the MCU port\n");

	of_property_read_u32(dev->of_node, "current-speed", &baud);
	serdev_device_set_baudrate(serdev, baud);
	serdev_device_set_flow_control(serdev, false);
	ret = serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);
	if (ret)
		return dev_err_probe(dev, ret, "cannot set 8N1\n");

	mcu->input = devm_input_allocate_device(dev);
	if (!mcu->input)
		return -ENOMEM;

	mcu->input->name = "Synology DS410j front panel";
	mcu->input->phys = DRV_NAME "/input0";
	mcu->input->id.bustype = BUS_HOST;
	mcu->input->dev.parent = dev;
	input_set_capability(mcu->input, EV_KEY, KEY_POWER);
	input_set_capability(mcu->input, EV_KEY, KEY_RESTART);

	ret = input_register_device(mcu->input);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register input device\n");

	ret = mcu_register_leds(mcu);
	if (ret)
		return ret;

	ret = mcu_setup_power_off(mcu, baud);
	if (ret)
		return ret;

	mcu->debugfs = debugfs_create_dir(DRV_NAME, NULL);
	debugfs_create_file("send", 0200, mcu->debugfs, mcu,
			    &mcu_dbg_send_fops);
	debugfs_create_file("rx", 0400, mcu->debugfs, mcu, &mcu_dbg_rx_fops);
	debugfs_create_file("counters", 0400, mcu->debugfs, mcu,
			    &mcu_dbg_counters_fops);

	dev_info(dev,
		 "Synology DS410j MCU at %u 8N1, power-off owned here; power button reports only on a ~4s hold\n",
		 baud);
	return 0;
}

static void mcu_remove(struct serdev_device *serdev)
{
	struct syno_mcu *mcu = serdev_device_get_drvdata(serdev);

	debugfs_remove_recursive(mcu->debugfs);
	if (mcu->uart)
		iounmap(mcu->uart);
}

static const struct of_device_id mcu_of_match[] = {
	{ .compatible = "synology,ds410j-mcu" },
	{ }
};
MODULE_DEVICE_TABLE(of, mcu_of_match);

static struct serdev_device_driver mcu_driver = {
	.probe	= mcu_probe,
	.remove	= mcu_remove,
	.driver	= {
		.name		= DRV_NAME,
		.of_match_table	= mcu_of_match,
	},
};
module_serdev_device_driver(mcu_driver);

MODULE_DESCRIPTION("Synology DS410j front-panel microcontroller on UART1");
MODULE_LICENSE("GPL");
