# SPDX-License-Identifier: GPL-2.0
# Out-of-tree test modules, built against the RUNNING kernel (they use
# only stable p2pdma/bio/dm APIs, not the md tree under test).
obj-m += md_p2p_test.o
obj-m += dm_errstat.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
