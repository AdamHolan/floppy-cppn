NASM ?= nasm
QEMU ?= qemu-system-i386
BUILD := build
IMAGE := $(BUILD)/cppn.img
C_IMAGE := $(BUILD)/cppn-c.img
CC ?= gcc
LD ?= ld
OBJCOPY ?= objcopy

.PHONY: all run debug c-image c-run c-debug clean

all: $(IMAGE)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/stage2.bin: asm/stage2.asm | $(BUILD)
	$(NASM) -f bin -Wall -Werror -w-reloc-abs-word -o $@ $<

$(BUILD)/boot.bin: asm/boot.asm $(BUILD)/stage2.bin | $(BUILD)
	@sectors=$$(( ($$(wc -c < $(BUILD)/stage2.bin) + 511) / 512 )); \
	if [ $$sectors -lt 1 ] || [ $$sectors -gt 2879 ]; then \
		echo "stage 2 has an invalid sector count: $$sectors"; exit 1; \
	fi; \
	$(NASM) -f bin -Wall -Werror -w-reloc-abs-word \
		-D STAGE2_SECTORS=$$sectors -o $@ $<
	@test "$$(wc -c < $@)" -eq 512 || \
		{ echo "boot sector is not exactly 512 bytes"; exit 1; }

$(IMAGE): $(BUILD)/boot.bin $(BUILD)/stage2.bin
	dd if=/dev/zero of=$@ bs=512 count=2880 status=none
	dd if=$(BUILD)/boot.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	@printf 'built %s (%s bytes; stage 2 is %s bytes)\n' \
		'$@' "$$(wc -c < '$@')" "$$(wc -c < '$(BUILD)/stage2.bin')"

run: $(IMAGE)
	$(QEMU) -machine pc -cpu pentium2 -m 16M \
		-drive file=$(IMAGE),format=raw,if=floppy -boot a

debug: $(IMAGE)
	$(QEMU) -S -s -machine pc -cpu pentium2 -m 16M \
		-drive file=$(IMAGE),format=raw,if=floppy -boot a

# 32-bit freestanding-C edition. GCC creates code but supplies no libc; NASM
# supplies the CPU-mode bridge; ld assigns physical addresses; objcopy removes
# ELF metadata to produce raw consecutive bytes for the BIOS loader.
$(BUILD)/c-entry.o: c32/entry.asm | $(BUILD)
	# entry.asm intentionally contains references that GNU ld resolves later:
	# protected_entry crosses NASM sections, __bss_* come from linker.ld, and
	# cppn_main comes from the C object. NASM 3.x warns for these perfectly normal
	# ELF relocations; keep every other warning fatal while disabling this group.
	$(NASM) -f elf32 -Wall -Werror -w-reloc -o $@ $<

$(BUILD)/cppn.o: c32/cppn.c | $(BUILD)
	$(CC) -m32 -std=c11 -Os -Wall -Wextra -Werror \
		-ffreestanding -fno-pie -fno-pic -fno-stack-protector \
		-fno-builtin -fno-asynchronous-unwind-tables -fno-unwind-tables \
		-nostdlib -c -o $@ $<

$(BUILD)/cppn-c.elf: $(BUILD)/c-entry.o $(BUILD)/cppn.o c32/linker.ld
	$(LD) -m elf_i386 -T c32/linker.ld -nostdlib --build-id=none \
		-Map=$(BUILD)/cppn-c.map -o $@ $(BUILD)/c-entry.o $(BUILD)/cppn.o

$(BUILD)/cppn-c-stage2.bin: $(BUILD)/cppn-c.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/c-boot.bin: asm/boot.asm $(BUILD)/cppn-c-stage2.bin | $(BUILD)
	@sectors=$$(( ($$(wc -c < $(BUILD)/cppn-c-stage2.bin) + 511) / 512 )); \
	if [ $$sectors -lt 1 ] || [ $$sectors -gt 127 ]; then \
		echo "C stage 2 is too large for this memory layout: $$sectors sectors"; exit 1; \
	fi; \
	$(NASM) -f bin -Wall -Werror -w-reloc-abs-word \
		-D STAGE2_SECTORS=$$sectors -o $@ $<
	@test "$$(wc -c < $@)" -eq 512 || \
		{ echo "boot sector is not exactly 512 bytes"; exit 1; }

$(C_IMAGE): $(BUILD)/c-boot.bin $(BUILD)/cppn-c-stage2.bin
	dd if=/dev/zero of=$@ bs=512 count=2880 status=none
	dd if=$(BUILD)/c-boot.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/cppn-c-stage2.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	@printf 'built %s (%s bytes; C stage 2 is %s bytes)\n' \
		'$@' "$$(wc -c < '$@')" \
		"$$(wc -c < '$(BUILD)/cppn-c-stage2.bin')"

c-image: $(C_IMAGE)

c-run: $(C_IMAGE)
	$(QEMU) -machine pc -cpu pentium2 -m 16M \
		-drive file=$(C_IMAGE),format=raw,if=floppy -boot a

c-debug: $(C_IMAGE)
	$(QEMU) -S -s -machine pc -cpu pentium2 -m 16M \
		-drive file=$(C_IMAGE),format=raw,if=floppy -boot a

clean:
	rm -f $(BUILD)/boot.bin $(BUILD)/stage2.bin $(IMAGE) \
		$(BUILD)/c-entry.o $(BUILD)/cppn.o $(BUILD)/cppn-c.elf \
		$(BUILD)/cppn-c.map $(BUILD)/cppn-c-stage2.bin \
		$(BUILD)/c-boot.bin $(C_IMAGE)
