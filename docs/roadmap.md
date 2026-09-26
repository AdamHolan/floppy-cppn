# From visual model to bootable artwork

## How much must be assembly?

If the final piece is self-contained and boots from a floppy, everything that
runs after the BIOS transfers control to address `0000:7C00` must exist in the
boot image as machine code or data. That does **not** mean everything belongs in
the 512-byte boot sector.

Use two stages:

- **Stage 1 (about 512 bytes):** establish a known stack and segment registers,
  remember the BIOS boot-drive number from `DL`, and use BIOS `INT 13h` to load
  stage 2 from known floppy sectors. Retry or display a short error if loading
  fails.
- **Stage 2 (many sectors):** switch to Mode 13h with `INT 10h, AH=00h,
  AL=13h`; optionally program the 256-color VGA DAC palette; evaluate the CPPN;
  write 64,000 palette-index bytes to `A000:0000`; mutate and redraw; read keys
  with BIOS `INT 16h` if desired.

The BIOS handles initial disk and video mode setup. It does not evaluate the
network, manage your state, or draw the pixels. Those mechanics belong in stage
2. You can keep using BIOS services in real mode; there is no need for protected
mode, an operating system, a filesystem, or a C runtime.

The boot sector should stay boring. Putting the art engine in stage 2 makes it
easy to change network size and debug it without playing byte-budget golf.

## The CPPN mechanics to port

The browser demo maps cleanly to assembly:

| Model operation | 16-bit implementation |
| --- | --- |
| Q8 value | signed 16-bit word |
| weighted edge | signed `IMUL`, then arithmetic shift right 8 |
| accumulated node input | signed 32-bit temporary, or a carefully bounded 16-bit sum |
| clamp | compares and conditional moves/branches |
| absolute value | sign test and `NEG` |
| square | `IMUL`, shift right 8 |
| tent | clamp then `256 - abs(x)` |
| step | sign test yielding -256 or 255 |
| pixel output | clamp, bias to 0..511, then scale to 0..255 |
| framebuffer write | store byte at `A000:offset` |
| mutation PRNG | shifts and XORs (a 16-bit xorshift is sufficient) |

On an original Celeron, 64,000 pixels times all fully connected edges is quite
feasible, but real-mode 16-bit multiplication is still the likely hot spot.
First make it correct. Later options include lowering node count, exploiting
incremental x coordinates, lookup tables, rendering every other pixel while
evolving, or moving the evaluator to 32-bit protected mode while retaining a
real-mode loader. None of those optimizations is needed for the first image.

One subtle distinction: Mode 13h is selected through video BIOS `INT 10h`, not
`INT 13h`. BIOS `INT 13h` is the disk service used to read the floppy. Once Mode
13h is active, the convenient framebuffer is 64,000 linear bytes at physical
address `0xA0000`, addressed in real mode as `A000:0000` through `A000:F9FF`.

## Connecting the goals

Treat every boundary as a testable contract:

1. **Disk contract:** stage 1 can load a recognizable stage-2 message.
2. **Video contract:** stage 2 can set Mode 13h and fill all 64,000 bytes with a
   known gradient.
3. **Math contract:** a tiny assembly test evaluates a few hard-coded coordinate
   inputs and shows their output bytes. Compare these with the demo inspector.
4. **Image contract:** the fixed seed produces the same complete indexed image
   in the demo and emulator (palette display differences aside).
5. **Evolution contract:** the same PRNG state and mutation step alter the same
   weights. Exact cross-platform identity is then possible, which is invaluable
   for debugging.
6. **Hardware contract:** only after the disk image is reliable in QEMU, write it
   to physical media and test boot, palette, timing, and keyboard behavior.

Freeze a known seed as a golden test vector. For example, record output indices
at `(0,0)`, `(160,100)`, and `(319,199)` plus a checksum of all 64,000 bytes.
That catches arithmetic, signedness, overflow, and coordinate-mapping errors.

## QEMU setup

On Debian or Ubuntu (including a Linux environment with graphical forwarding):

```sh
sudo apt install qemu-system-x86 nasm make
```

Build a raw 1.44 MB floppy image, then boot it as a floppy:

```sh
make
qemu-system-i386 \
  -machine pc \
  -cpu pentium2 \
  -m 16M \
  -drive file=build/cppn.img,format=raw,if=floppy \
  -boot a
```

`-cpu pentium2` is a useful conservative approximation for an early Celeron,
but the real-mode instructions proposed here also work on much older x86 CPUs.
Use `-cpu help` to see the exact CPU models supported by the installed QEMU.
CPU emulation will not perfectly reproduce the physical machine's BIOS or VGA
timing, so keep a real-hardware test milestone.

Useful debugging variants:

```sh
# Freeze before the first instruction and expose QEMU's GDB stub on port 1234.
qemu-system-i386 -S -s \
  -drive file=build/cppn.img,format=raw,if=floppy -boot a

# Log guest CPU state and interrupts (the file can become large).
qemu-system-i386 -d int,cpu_reset -D build/qemu.log \
  -drive file=build/cppn.img,format=raw,if=floppy -boot a
```

Then connect a multi-architecture GDB build with:

```sh
gdb-multiarch
(gdb) set architecture i8086
(gdb) target remote :1234
(gdb) break *0x7c00
(gdb) continue
```

For quick iteration, the eventual Makefile should assemble stage 1 and stage 2,
check that stage 1 is exactly 512 bytes with signature `55 AA`, calculate the
number of stage-2 sectors, and create a deterministic 1.44 MB raw image. Avoid a
filesystem at first: consecutive sectors are simpler and make the relevant BIOS
mechanics visible.

## Physical-machine cautions

- Confirm whether the Celeron machine has a BIOS/legacy boot path and a real
  floppy controller or a USB floppy. Some USB firmware emulates enough of
  `INT 13h` to boot, but behavior varies.
- Preserve `DL`; BIOS supplies the actual boot drive there. Do not assume it is
  always zero.
- BIOS calls may clobber registers. Establish explicit calling conventions.
- A normal 1.44 MB floppy uses 80 cylinders, 2 heads, and 18 sectors per track.
  Classic `INT 13h` reads use CHS values and sectors are numbered from 1.
- Never test raw-image writes against an ambiguously named host disk. Resolve
  and verify the exact removable-device target first.

