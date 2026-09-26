; =============================================================================
; entry.asm -- the narrow bridge from the 16-bit BIOS world to 32-bit C
; =============================================================================
;
; boot.asm loaded this whole stage at physical 0x10000 and jumped to 1000:0000.
; We begin in BIOS-compatible 16-bit real mode. This file performs only the work
; C cannot conveniently do: set Mode 13h, enter protected mode, create a flat
; 32-bit execution environment, clear C's .bss, and call cppn_main().
;
; After protected mode begins, BIOS interrupts cannot be called directly. The C
; artwork is therefore hands-free. A later real-mode thunk could add BIOS input.
; =============================================================================
bits 16

%define STAGE2_BASE   0x10000
%define CODE_SELECTOR 0x08       ; GDT entry 1
%define DATA_SELECTOR 0x10       ; GDT entry 2

section .start
global stage2_start
extern cppn_main
extern __bss_start
extern __bss_end

stage2_start:
    ; CS is 1000h after boot.asm's far jump. Make the other real-mode segments
    ; agree. CLI prevents an interrupt from using a half-configured stack.
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xfffe              ; temporary stack at physical 0x1FFFE
    cld

    ; Video BIOS function AH=00h, mode AL=13h. Do this before protected mode,
    ; while the BIOS Interrupt Vector Table and real-mode assumptions are valid.
    mov ax, 0x0013
    int 0x10

    ; LGDT reads a 16-bit size plus 32-bit base. The *location of that little
    ; descriptor* must be addressed as an offset within DS=1000h, not as its
    ; linked physical address near 0x10000. `$$` means the start of this NASM
    ; section, so the subtraction is a small section-relative offset NASM can
    ; resolve now; no impossible 16-bit linker relocation remains.
    lgdt [gdt_descriptor - $$]

    ; Set CR0 bit zero, PE (Protected-mode Enable). With no OS above us, this
    ; boot code already executes at the highest privilege level.
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; A far jump reloads CS from the GDT and flushes prefetched real-mode code.
    ; `dword` forces the 32-bit destination offset used by our flat code segment.
    jmp dword CODE_SELECTOR:protected_entry

bits 32
protected_entry:
    ; Protected-mode segment registers hold GDT selectors, not literal bases.
    ; Our data descriptor has base zero and a 4 GiB limit, producing flat memory.
    mov ax, DATA_SELECTOR
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Stack grows downward from conventional RAM below the VGA aperture.
    mov esp, 0x90000
    xor ebp, ebp
    cld

    ; Variables without explicit initializers belong to .bss and must begin at
    ; zero. A raw binary has no OS loader to do this, so REP STOSB clears them.
    mov edi, __bss_start
    mov ecx, __bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    ; Ordinary 32-bit cdecl call into the high-level half of the program.
    call cppn_main

    ; cppn_main should never return. If it does, halt safely instead of running
    ; into arbitrary data. Interrupts are still disabled, so HLT remains asleep.
.unexpected_return:
    hlt
    jmp .unexpected_return

; A GDT descriptor is an awkward historical 8-byte bit field. These standard
; constants mean: base 0, 4 GiB limit, 32-bit, ring 0, code or writable data.
align 8
gdt_start:
    dq 0x0000000000000000      ; selector 00h: mandatory null descriptor
    dq 0x00cf9a000000ffff      ; selector 08h: flat executable code
    dq 0x00cf92000000ffff      ; selector 10h: flat writable data
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1 ; LGDT wants table size minus one
    dd gdt_start               ; linker's 32-bit physical address of the GDT

section .note.GNU-stack noalloc noexec nowrite progbits
