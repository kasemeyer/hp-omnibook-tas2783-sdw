# Out-of-tree overrides against the running kernel's headers.
# NOTE: Arch's linux is GCC-built. Do NOT set LLVM=1 here -- that is only
# needed for clang-built kernels such as CachyOS.
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

.PHONY: all intel sdca tas2783 clean
all: intel sdca tas2783

intel:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/build-sdw-intel

sdca:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/build-sdca

# fetch-src.sh leaves this one without sources on a kernel the resume series
# does not apply to; the speaker fix does not need it.
tas2783:
	@if [ -f $(CURDIR)/build-tas2783/tas2783-sdw.c ]; then \
		$(MAKE) -C $(KDIR) M=$(CURDIR)/build-tas2783; \
	else \
		echo "build-tas2783: no sources for this kernel, skipping"; \
	fi

clean:
	-$(MAKE) -C $(KDIR) M=$(CURDIR)/build-sdw-intel clean
	-$(MAKE) -C $(KDIR) M=$(CURDIR)/build-sdca clean
	-$(MAKE) -C $(KDIR) M=$(CURDIR)/build-tas2783 clean
