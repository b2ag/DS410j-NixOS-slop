# Out-of-tree build for the DS410j MCU driver.
#
# KERNEL_DIR is supplied by nixos/mcu-driver.nix and points at the build tree of
# the exact kernel the image will run, so the module's vermagic matches.
obj-m := synology-mcu.o

KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) modules

modules_install:
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) \
		INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) modules_install

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) clean

.PHONY: all modules_install clean
