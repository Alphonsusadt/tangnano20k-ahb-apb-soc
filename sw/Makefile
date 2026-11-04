# Builds sw/firmware.hex, one 32-bit word per line, for $readmemh into rom_mem.
# Run from sw/ on Linux or WSL. Simulation builds its own image through NAME and
# CFLAGS_EXTRA, so it can never end up in the FPGA build.

NAME = firmware

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
SIZE    := $(CROSS)size

# -mstrict-align stops the compiler creating the misaligned stores that the
# OBI-to-AHB adapter refuses.
CFLAGS := -march=rv32imc -mabi=ilp32 -mstrict-align -Os -Wall -Wextra -ffreestanding \
          -nostdlib -nostartfiles -fno-builtin $(CFLAGS_EXTRA)

$(NAME).hex: $(NAME).bin
	od -An -tx4 -v -w4 $< | sed 's/ //g' > $@

$(NAME).bin: $(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(NAME).elf: crt0.S main.c link.ld
	$(CC) $(CFLAGS) -T link.ld -o $@ crt0.S main.c
	$(SIZE) $@

clean:
	rm -f $(NAME).elf $(NAME).bin $(NAME).hex

.PHONY: clean
