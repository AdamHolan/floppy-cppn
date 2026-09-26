# Floppy CPPN

Floppy CPPN is a generative-art experiment for my old Celeron Dell Dimension: 
a small compositional pattern-producing network (CPPN) turns pixel coordinates 
into colors. The repo contains an interactive browser prototype and build targets
for the raw 1.44 MB floppy image. The bootable programs load through the BIOS and 
draw directly into the 320 × 200 VGA Mode 13h framebuffer, without an operating 
system or filesystem.

<img width="637" height="478" alt="image" src="https://github.com/user-attachments/assets/e7f23b76-5849-4389-9d8a-8bc8ea237096" />
<img width="318" height="239" alt="image" src="https://github.com/user-attachments/assets/297c3e02-b0a3-4de1-b727-359d525c2eb3" />


## Try the browser prototype

Open [demo/index.html](demo/index.html) directly in a browser. It needs no
server or dependencies. You can mutate once, start or pause automatic mutation,
and click a pixel to inspect its inputs and each network node's output. 
I ended up changing the final architecture as I went along, and now the browser 
technically displays one layer of what I would later make three layers mapped to 
R, G and B. You can still see it if you do make run but I never animated it.

The demo uses Q8 fixed-point integer arithmetic (256 represents 1.0), a
256-color palette, and `linear`, `abs`, `square`, `tent`, and `step` activation
functions. Its four inputs are normalized x and y coordinates, an approximate
distance from the center (`abs(x) + abs(y)`), and a constant. Two six-node hidden
layers feed one output node, which produces a palette index for each pixel.

The starting network is randomized with `Math.random()`. **Reset seed** creates
a new starting network and resets the mutation counter and xorshift PRNG state;
it does not reproduce the previous image. Mutation changes weights and
occasionally a hidden-node activation. It does not score, train, or select
images.

## Build the assembly floppy image

You need NASM, Make, standard Unix utilities, and QEMU to run the image:

```sh
make
make run
```

`make` creates `build/cppn.img`. Its 512-byte boot sector reads stage 2 from
floppy sectors using BIOS `INT 13h`. Stage 2 selects VGA Mode 13h, programs a
256-entry palette, evaluates a Q8 fixed-point network, and writes 64,000 color
indices directly to video memory at `A000:0000`. After drawing one frame, it
waits for a key and asks the BIOS to reboot.

The assembly renderer uses six hidden nodes and one output node. Its weights
and activations are built into stage 2; it does not mutate the image while
running.

## Build the freestanding C floppy image

This version also needs GCC and binutils capable of generating 32-bit x86 code:

```sh
make c-image
make c-run
```

`make c-image` creates `build/cppn-c.img`. It reuses the BIOS boot sector, then
an assembly entry point selects Mode 13h, sets up a GDT, enters 32-bit protected
mode, initializes the stack and `.bss`, and calls freestanding C. The C code
programs the VGA palette through I/O ports and writes pixels to the framebuffer
at physical address `0xA0000`.

The current C edition repeatedly renders and changes its network parameters.
Its parameter walk uses fixed-point phase and velocity values that wrap around
the allowed weight range. There is currently no delay between frames and no
keyboard control. All initial nodes are set to `linear`, and its red and green
palette bits come from hidden nodes while blue comes from the output node.

The browser, assembly, and C versions are related explorations, **not**
pixel-identical ports of one network. In particular, their topology, starting
weights, color mapping, and mutation behavior differ.

## Files and development status

| Path | Purpose |
| --- | --- |
| `demo/` | Browser prototype and pixel inspector |
| `asm/boot.asm` | Shared 512-byte BIOS floppy loader |
| `asm/stage2.asm` | 16-bit assembly CPPN and VGA renderer |
| `c32/` | Protected-mode entry, linker script, and freestanding C renderer |
| `Makefile` | Raw floppy-image builds and QEMU run/debug targets |
| `docs/roadmap.md` | Original design roadmap and debugging ideas |
| `cppn.c` | Earlier C experiment; not part of either image build |

Both image targets build from the current sources. The roadmap contains early
milestones, some of which are already implemented. Physical-floppy and physical
PC testing are not documented here.

For QEMU's GDB stub, use `make debug` or `make c-debug`. If your QEMU executable
has a different name, override `QEMU`, for example:

```sh
make run QEMU=qemu-system-x86_64
```
