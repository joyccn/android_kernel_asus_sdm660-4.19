# make sure that the environment variables ARCH and CROSS_COMPILE
# are set for your architecture and cross compiler.
# And that KDIR points to the kernel to build against.
#
# e.g.:
# export ARCH=arm
# export CROSS_COMPILE=arm-linux-gnueabihf-
# export KDIR=../linux

# debugging support (also enables trace_printk)
EXTRA_CFLAGS += -DDEBUG

EXTRA_CFLAGS += -I$(src)/inc
EXTRA_CFLAGS += -Werror

obj-$(CONFIG_SND_SOC_TFA9874) := snd-soc-tfa9874.o

snd-soc-tfa9874-objs += src/tfa98xx.o
snd-soc-tfa9874-objs += src/tfa_container.o
snd-soc-tfa9874-objs += src/tfa_dsp.o
snd-soc-tfa9874-objs += src/tfa_init.o

# Disable enum conversion warning
subdir-ccflags-y := $(call cc-disable-warning, enum-conversion)

ifdef TFA_DEBUG
EXTRA_CFLAGS += -DTFA_DEBUG -DDEBUG
snd-soc-tfa9874-objs += src/tfa_debug.o
endif
