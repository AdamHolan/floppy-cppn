; =============================================================================
; boot.asm -- the first 512 bytes the PC executes from our floppy
; =============================================================================
;
; Mental model
; ------------
; The CPU does not initially know about files, directories, CPPNs, or even our
; second assembly file. The BIOS reads exactly the first 512-byte sector of the
; selected boot disk into physical address 0x07C00 and jumps there.
;
; This tiny program's whole job is therefore:
;
;   1. Put the CPU registers into a state we understand.
;   2. Ask the BIOS to read the rest of our program from the floppy.
;   3. Jump to that newly loaded program (stage 2).
;
; Keeping this stage boring is intentional. There are only 510 usable bytes;
; the final two bytes must be the boot signature 0x55, 0xAA.
;
; x86 real-mode addresses
; -----------------------
; Unlike the flat address space you may remember from ARM, 16-bit real mode
; normally describes an address with SEGMENT:OFFSET. The physical address is:
;
;                 physical = segment * 16 + offset
;
; Thus 0000:7C00 and 07C0:0000 both mean physical address 0x07C00. Memory
; operands normally use DS as their segment; stack operations use SS; string
; destinations use ES. We explicitly initialize all of those that matter.
;
; BIOS interfaces used here
; -------------------------
; INT means "software interrupt." It is rather like calling a firmware routine
; through a fixed vector. Registers are the arguments and results.
;
;   INT 13h, AH=02h  read disk sectors
;   INT 13h, AH=00h  reset disk system
;   INT 10h, AH=0Eh  print one teletype character
;
; The BIOS enters us with DL containing the boot drive number. Save it! A real
; floppy is usually 00h, but assuming that makes USB-floppy/BIOS emulation less
; reliable.
; =============================================================================
bits 16
org 0x7c00

; BITS 16 tells NASM to encode 16-bit real-mode instructions.
; ORG tells NASM that byte zero of this file will live at offset 0x7C00.
; ORG emits no bytes; it only makes labels receive the correct numeric address.

%ifndef STAGE2_SECTORS
%error "assemble with -D STAGE2_SECTORS=<count>"
%endif

start:
    ; Mask hardware interrupts while SS:SP is temporarily inconsistent. An
    ; interrupt pushes data on the stack, which would be disastrous before a
    ; valid stack exists.
    cli

    ; XORing a register with itself is the traditional compact way to make 0.
    ; AX is a 16-bit register. AH and AL are its upper and lower bytes.
    xor ax, ax

    ; DS=0 means [some_label] addresses physical 0:some_label. Because ORG is
    ; 7C00h, our variables have offsets around 7C00h and are found correctly.
    mov ds, ax
    mov es, ax

    ; The stack grows downward. It begins immediately below our boot sector.
    ; This is plenty for this tiny loader, which has almost no nested calls.
    mov ss, ax
    mov sp, 0x7c00

    ; The stack is valid now, so hardware interrupts may happen again.
    sti

    ; LODSB and other string operations can walk forward or backward depending
    ; on the direction flag. Clear it once so LODSB increments SI.
    cld

    ; Brackets mean memory access in Intel syntax. Without brackets this would
    ; refer to the address/value itself rather than the byte stored there.
    mov [boot_drive], dl

    ; We chose physical address 0x10000 for stage 2:
    ;     0x1000 * 16 + 0x0000 = 0x10000
    ; INT 13h writes disk data to ES:BX, hence ES=1000h and BX=0000h.
    mov ax, 0x1000
    mov es, ax
    xor bx, bx

    ; The Makefile assembles stage 2 first, calculates ceil(bytes/512), and
    ; passes that number to NASM as STAGE2_SECTORS. This is how the loader knows
    ; how much to read without understanding a filesystem.
    mov word [remaining], STAGE2_SECTORS

    ; A standard 1.44 MB floppy uses CHS addressing:
    ;   80 cylinders, 2 heads, 18 sectors per track.
    ; Sector numbers begin at ONE, not zero. Sector 1 already contains us, so
    ; stage 2 starts at cylinder 0, head 0, sector 2.
    mov byte [cylinder], 0
    mov byte [head], 0
    mov byte [sector], 2

.read_next:
    ; CMP performs a subtraction only for its status flags; it throws the
    ; numerical result away. JE branches when the values were equal.
    cmp word [remaining], 0
    je .launch

    ; Floppies are fallible. Give each sector three chances before stopping.
    mov byte [retries], 3

.retry:
    ; INT 13h/AH=02h arguments:
    ;   AL = number of consecutive sectors to read
    ;   CH = cylinder (low 8 bits; enough for our 0..79 floppy cylinders)
    ;   CL = sector (bits 0..5; high cylinder bits normally occupy bits 6..7)
    ;   DH = head
    ;   DL = BIOS drive
    ;   ES:BX = destination buffer
    ; We read one sector per call. That is slower than large reads, but avoids
    ; track-boundary and 64 KiB DMA-boundary surprises while we are learning.
    mov ah, 0x02
    mov al, 1
    mov ch, [cylinder]
    mov cl, [sector]
    mov dh, [head]
    mov dl, [boot_drive]
    int 0x13

    ; BIOS reports disk success by clearing Carry Flag (CF), failure by setting
    ; it. JNC means "jump if no carry."
    jnc .read_ok

    ; AH=00h resets the disk subsystem. AX=0 conveniently sets AH and AL to 0.
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    dec byte [retries]
    jnz .retry

    ; All retries failed. Print a useful message instead of executing whatever
    ; incomplete garbage happens to be in the stage-2 buffer.
    mov si, disk_error
    call print

    ; "$" in NASM means the current address. Jumping to ourselves is an
    ; intentional infinite loop. The machine remains stopped on the error.
    jmp $

.read_ok:
    ; One sector (512 = 0x200 bytes) was placed at ES:BX, so advance BX to the
    ; next destination. A 16-bit register wraps after 0xFFFF. ADD sets CF if
    ; that wrap happened.
    add bx, 512
    jnc .buffer_ok

    ; Increasing the segment by 1000h moves its physical base by 10000h (64
    ; KiB). BX has wrapped to zero, so ES:BX continues at the next physical byte.
    ; Our current stage 2 is much smaller, but this makes the loader robust.
    mov ax, es                ; advance ES if BX wrapped at 64 KiB
    add ax, 0x1000
    mov es, ax
.buffer_ok:
    ; Account for the sector just read, then advance the disk CHS position.
    dec word [remaining]
    inc byte [sector]

    ; Valid sector numbers are 1..18. If the increment produced 19, wrap the
    ; sector to 1 and move to the other head (the other side of the disk).
    cmp byte [sector], 19
    jb .read_next
    mov byte [sector], 1

    ; XOR with 1 toggles a value between 0 and 1. If the result is 1, we have
    ; moved head 0 -> head 1 on the same cylinder. If it is 0, we moved head 1
    ; -> head 0 and must advance to the next cylinder.
    xor byte [head], 1
    jnz .read_next
    inc byte [cylinder]
    jmp .read_next

.launch:
    ; Preserve the conventional boot-drive value for stage 2, even though our
    ; current stage 2 does not use it. This is a FAR jump: it changes CS and IP,
    ; landing at the first byte loaded at 1000:0000.
    mov dl, [boot_drive]
    jmp 0x1000:0x0000

print:
    ; DS:SI points at a zero-terminated string. LODSB means:
    ;     AL = byte [DS:SI]
    ;     SI = SI + 1             (because CLD cleared the direction flag)
    lodsb
    test al, al
    jz .done

    ; BIOS teletype output. AL is the character; page 0 and attribute 7 are
    ; harmless conventional values in BX. Then repeat for the next character.
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp print
.done:
    ret

; Loader state. DB reserves/emits one byte; DW emits one 16-bit word. These
; live inside the 512-byte boot sector alongside the machine instructions.
boot_drive db 0
remaining  dw 0
cylinder   db 0
head       db 0
sector     db 0
retries    db 0
disk_error db 'Floppy read error', 0

; Fill unused bytes with zeros until file offset 510. $$ is the beginning of
; the current section and $ is the current position, so ($-$$) is current size.
times 510-($-$$) db 0

; x86 is little-endian: DW 0xAA55 emits bytes 55 AA. The BIOS looks for these
; at offsets 510 and 511 before it considers this sector bootable.
dw 0xaa55
