; =============================================================================
; stage2.asm -- integer CPPN art rendered directly into VGA memory
; =============================================================================
;
; Where are we?
; -------------
; boot.asm loaded this entire file at 1000:0000 and made a far jump here. That
; is physical address 0x10000 because real-mode addresses mean segment*16+offset.
; There is no OS, process, runtime, heap, or standard library. BIOS firmware and
; hardware ports are the only services below us.
;
; What is this network?
; ---------------------
; For every pixel, we calculate these four signed fixed-point inputs:
;
;   x       horizontal position, about -256 on left to +255 on right
;   y       vertical position,   about -256 on top  to +255 on bottom
;   radius  abs(x)+abs(y), clamped to 255 (a cheap diamond-shaped radius)
;   bias    constant 256, allowing a weight to add a constant influence
;
; Those four values feed six hidden nodes. The six hidden outputs feed one
; output node. The final output becomes a byte from 0..255, which is both a
; palette index and the byte written into video memory.
;
; Q8 fixed-point arithmetic
; -------------------------
; We pretend integers have an invisible binary point eight bits from the right:
;
;      integer storage       interpreted value
;             256                  +1.0
;             128                  +0.5
;            -256                  -1.0
;
; Multiplying two Q8 values gives a Q16 result, so we shift right by eight to
; return to Q8. Fixed point is not mandatory on a Celeron, but it is wonderfully
; explicit and reproducible, and avoids setting up an x87 floating-point model.
;
; VGA Mode 13h
; ------------
; Mode 13h is 320*200 = 64,000 pixels with one byte per pixel. The framebuffer
; begins at physical address 0xA0000, represented as A000:0000. Pixel (x,y) is:
;
;                     offset = y*320 + x
;
; Because we render left-to-right and top-to-bottom, we do not calculate that
; formula explicitly. DI simply advances once after every pixel, from 0 through
; 63,999. ES remains A000h, and STOSB writes AL to ES:DI then increments DI.
; =============================================================================
bits 16
org 0

; Stage 2 lives at offset zero inside segment 1000h, so ORG 0 is correct. Labels
; are offsets relative to DS=CS=1000h rather than physical addresses.

%define ACT_LINEAR 0
%define ACT_ABS    1
%define ACT_SQUARE 2
%define ACT_TENT   3
%define ACT_STEP   4
; A hidden-node record has:
;   byte activation, byte padding, word bias, four word weights
; = 1+1+2+(4*2) = 12 bytes. Keeping data in records lets one evaluator run every
; node instead of hard-coding separate arithmetic for each one.
%define NODE_SIZE  12

start:
    ; A far jump changed CS but did not automatically make DS or SS equal CS.
    ; Normalize them so labels refer to this stage and the stack occupies the
    ; upper end of the same 64 KiB segment. As in boot.asm, do not permit an
    ; interrupt while SS:SP is half-updated.
    cli
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0xfffe
    sti
    cld

    ; Video BIOS function AH=00h selects a mode given by AL. AX=0013h therefore
    ; asks for VGA mode 13h. The BIOS performs the unpleasant VGA setup for us.
    mov ax, 0x0013
    int 0x10

    ; The mode has a palette already, but installing our own makes indices have
    ; a simple, deliberate relationship to red/green/blue components.
    call set_palette

    ; ES is the implicit destination segment used by STOSB. DS still points at
    ; our code/data/network. Keeping DS and ES different is how [inputs] and
    ; framebuffer writes coexist without segment prefixes everywhere.
    mov ax, 0xa000
    mov es, ax
    xor di, di                ; ES:DI = A000:0000, first framebuffer byte
    xor bp, bp                ; BP is our y loop counter, beginning at row 0

.row:
    xor bx, bx                ; BX is x, reset to column 0 for each row
.pixel:
    ; Map coordinates approximately into signed Q8 [-256,255].
    ; floor(x*511/319) = x + floor(x*192/319). Splitting it keeps
    ; the intermediate product below 65536 on a 16-bit processor.
    ; Exact mapping wanted: floor(x*511/319)-256. The direct product can exceed
    ; 16 bits, so use the identity 511=319+192:
    ;
    ; floor(x*511/319) = x + floor(x*192/319)
    ;
    ; MUL uses unsigned AX*CX and produces the full 32-bit result in DX:AX.
    ; DIV consumes DX:AX, returns quotient in AX and remainder in DX.
    mov ax, bx
    mov cx, 192
    mul cx
    mov cx, 319
    div cx
    add ax, bx
    sub ax, 256
    mov [inputs + 0], ax

    ; Same trick vertically, where 511=199+312.
    mov ax, bp
    mov cx, 312
    mul cx                   ; floor(y*511/199) = y + floor(y*312/199)
    mov cx, 199
    div cx
    add ax, bp
    sub ax, 256
    mov [inputs + 2], ax

    ; Compute the cheap radial input. We save abs(x) in DX only briefly, then
    ; add abs(y). A Euclidean sqrt(x*x+y*y) would be prettier mathematically but
    ; far more expensive and unnecessary for a CPPN coordinate feature.
    mov ax, [inputs + 0]
    call abs_ax
    mov dx, ax
    mov ax, [inputs + 2]
    call abs_ax
    add ax, dx
    cmp ax, 255
    jle .radius_ok
    mov ax, 255
.radius_ok:
    mov [inputs + 4], ax

    ; The constant input is what neural-net literature usually calls the bias
    ; input. Each node ALSO has a bias field in this teaching implementation;
    ; that redundancy is harmless and makes both mechanisms visible.
    mov word [inputs + 6], 256

    ; We must temporarily reuse BX (currently x), BP (currently y), and DI
    ; (currently framebuffer offset) while evaluating the network. PUSH copies
    ; each onto the stack so POP can restore them afterward. Stack order is LIFO.
    push bx
    push bp
    push di

    ; SI walks node records; DI walks the hidden-output array. CX is both the
    ; loop counter and, inside eval_node, the number of incoming values.
    mov si, hidden_nodes
    mov di, hidden
    mov cx, 6
.hidden_loop:
    ; LOOP needs the outer CX=number-of-hidden-nodes. eval_node needs CX=4 and
    ; advances SI/DI-related registers, so preserve the outer values explicitly.
    push cx
    push si
    push di
    mov bx, inputs
    mov cx, 4
    call eval_node
    pop di
    pop si
    ; This MUST be MOV [DI],AX, not STOSW: hidden state belongs in DS, while a
    ; string store would silently write through ES into VGA memory.
    mov [di], ax
    add di, 2
    add si, NODE_SIZE
    pop cx

    ; LOOP decrements CX and branches while it is nonzero. It resembles a tiny
    ; fused SUBS/BNE pair from ARM, though modern x86 code often avoids LOOP.
    loop .hidden_loop

    ; The output node has six inputs rather than four, but eval_node is generic:
    ; change BX to the hidden array and CX to six.
    mov si, output_node
    mov bx, hidden
    mov cx, 6
    call eval_node
    ; eval_node returns signed Q8 in [-256,+255]. Translate it to [0,511], halve
    ; it, then defensively clamp to a legal byte/palette index [0,255]. SAR is an
    ; arithmetic right shift: it preserves the sign bit, unlike SHR.
    add ax, 256
    sar ax, 1
    cmp ax, 0
    jge .not_low
    xor ax, ax
.not_low:
    cmp ax, 255
    jle .not_high
    mov ax, 255
.not_high:
    ; Recover the framebuffer position and loop coordinates in reverse order.
    pop di
    pop bp
    pop bx
    stosb                     ; [ES:DI]=AL, then DI++ because direction flag=0

    ; Advance the nested x/y loops. JB is an unsigned comparison, appropriate
    ; because screen coordinates never go negative.
    inc bx
    cmp bx, 320
    jb .pixel
    inc bp
    cmp bp, 200
    jb .row

    ; Rendering is finished. BIOS INT 16h/AH=00h waits until a key is available
    ; and returns it. INT 19h asks BIOS to bootstrap again. Firmware differs, so
    ; the infinite loop is a safe fallback if INT 19h unexpectedly returns.
    xor ah, ah
    int 0x16
    int 0x19
    jmp $

; =============================================================================
; eval_node -- the heart of the neural network
; =============================================================================
; Inputs:
;   DS:SI -> node record: activation, pad, bias, weights...
;   DS:BX -> array of signed Q8 input words
;   CX    = number of inputs/weights
;
; Output:
;   AX    = activated result, clamped to signed Q8 [-256,+255]
;
; Mathematical operation:
;
;   sum = node_bias + SUM((input[i] * weight[i]) >> 8)
;   output = activation(clamp(sum, -256, 255))
;
; The accumulator is 32 bits in memory (`sum`) so several products cannot
; silently overflow a 16-bit register. On ARM you might naturally keep this in
; a 32-bit general register; real-mode x86 still has 32-bit registers on a
; Celeron, but this version makes the 16-bit carry mechanics visible.
eval_node:
    ; Calling convention for this private routine: preserve BP, DI, and SI.
    ; After these pushes, BP points at the saved original SI on the stack. We use
    ; that later to recover the activation byte after SI/DI have moved.
    push bp
    push di
    push si
    mov bp, sp
    mov di, si
    ; Copy the signed 16-bit node bias into our 32-bit sum with sign extension.
    ; The low word goes at [sum], high word is 0000 for nonnegative or FFFF for
    ; negative. This is the manual memory equivalent of sign extension.
    mov ax, [di + 2]
    mov [sum], ax
    mov word [sum + 2], 0
    test ax, ax
    jns .sum_sign_ok
    mov word [sum + 2], -1
.sum_sign_ok:
    add di, 4
.edge:
    ; IMUL with one explicit operand multiplies signed AX by signed word [DI],
    ; producing a full signed 32-bit result in DX:AX (high:low).
    mov ax, [bx]
    imul word [di]

    ; We need (DX:AX >> 8), and only its low 16 bits. Imagine bytes:
    ;
    ;       DX high | DX low | AX high | AX low
    ;
    ; After shifting right by one byte, the desired low word consists of old
    ; DX-low as its high byte and old AX-high as its low byte. These two MOVs
    ; construct exactly that without requiring a 386-only SHRD instruction.
    mov al, ah
    mov ah, dl

    ; CWD sign-extends this 16-bit shifted product back into DX:AX so it can be
    ; added to our 32-bit memory accumulator. ADD handles the low word; ADC adds
    ; the high word plus any carry from the low-word addition.
    cwd
    add [sum], ax
    adc [sum + 2], dx
    add bx, 2
    add di, 2
    loop .edge

    ; Clamp the signed 32-bit sum into [-256,+255]. For the small current network
    ; the high word should normally be 0000 or FFFF, but handling it explicitly
    ; documents the signed representation and protects later weight experiments.
    mov ax, [sum]
    cmp word [sum + 2], 0
    je .positive_range
    cmp word [sum + 2], -1
    jne .force_low
    test ax, ax
    jns .force_low
    cmp ax, -256
    jge .activated
.force_low:
    mov ax, -256
    jmp .activated
.positive_range:
    test ax, ax
    js .force_high
    cmp ax, 255
    jle .activated
.force_high:
    mov ax, 255

.activated:
    ; [BP] is the SI value saved at entry, pointing back to the node record.
    ; DL receives its activation ID. The comparisons form a small switch table.
    mov si, [bp]              ; saved original SI
    mov dl, [si]
    cmp dl, ACT_LINEAR
    je .done
    cmp dl, ACT_ABS
    je .absolute
    cmp dl, ACT_SQUARE
    je .square
    cmp dl, ACT_TENT
    je .tent
    ; Any unknown activation ID falls through to STEP. TEST AX,AX sets flags
    ; based on AX without changing it; JS tests the sign flag.
    test ax, ax
    js .step_low
    mov ax, 255
    jmp .done
.step_low:
    mov ax, -256
    jmp .done
.absolute:
    ; ABS(-256) is +256, one above our maximum +255, hence the extra clamp.
    call abs_ax
    cmp ax, 255               ; abs(-256) needs clamping
    jle .done
    mov ax, 255
    jmp .done
.square:
    ; Q8 square: AX*AX gives Q16 in DX:AX, then use the same byte-selection trick
    ; to divide by 256. Since the clamped input magnitude is <=256, the result is
    ; safely within 0..256 (and -256 squared represents exactly +256 here).
    imul ax
    mov al, ah                ; DX:AX >> 8
    mov ah, dl
    cmp ax, 255               ; (-256)^2 / 256 is +256: clamp that edge case
    jle .done
    mov ax, 255
    jmp .done
.tent:
    ; tent(x) = 255-abs(x). It peaks at the center and falls toward both edges.
    ; Combinations of ABS, SQUARE, and TENT introduce the folds and symmetries
    ; that make a CPPN much richer than an ordinary linear network.
    call abs_ax
    neg ax
    add ax, 255
.done:
    pop si
    pop di
    pop bp
    ret

abs_ax:
    ; Tiny helper: if AX is negative, two's-complement NEG makes it positive.
    ; Like ARM's conditional negate pattern, TEST sets flags and JNS skips work
    ; when the sign flag is clear.
    test ax, ax
    jns .done
    neg ax
.done:
    ret

; =============================================================================
; set_palette -- assign RGB colors to our 256 byte-sized indices
; =============================================================================
; The VGA DAC exposes I/O ports rather than normal memory:
;   03C8h = palette index to begin changing
;   03C9h = successive red, green, blue channel values
;
; Each DAC channel accepts 6 meaningful bits (0..63). We divide the eight bits
; of an index as RRR GGG BB: 3 red bits, 3 green bits, 2 blue bits. This gives
; 8*8*4 = 256 distinct colors. OUT writes AL to the port number held in DX.
set_palette:
    ; Begin at palette entry zero, then point DX at the RGB data port.
    xor al, al
    mov dx, 0x3c8
    out dx, al
    inc dx
    xor bx, bx
.entry:
    ; Red = index bits 7..5, expanded roughly into VGA's 0..63 range.
    mov ax, bx
    shr ax, 5
    and al, 7
    shl al, 3
    out dx, al
    ; Green = index bits 4..2.
    mov ax, bx
    shr ax, 2
    and al, 7
    shl al, 3
    out dx, al
    ; Blue = index bits 1..0.
    mov ax, bx
    and al, 3
    shl al, 4
    out dx, al
    ; BL is the current palette index. Incrementing FFh wraps to 00h and sets
    ; Zero Flag; JNZ therefore repeats exactly 256 times without a 16-bit count.
    inc bl
    jnz .entry
    ret

; =============================================================================
; Mutable network state and immutable genome records
; =============================================================================
; TIMES N DW 0 emits N zero-valued words. These arrays are reused for every
; pixel. They are not dynamically allocated; they are ordinary bytes embedded
; in our stage-2 binary and writable after the BIOS copies it into RAM.
;
; Keep code and data in one flat-binary section. In NASM 3.x the ALIGN macro
; can cause absolute 16-bit references around ORG 0 to be diagnosed as
; section-crossing relocations. Unaligned word access is valid on x86, so no
; alignment directive is needed here.
inputs: times 4 dw 0
hidden: times 6 dw 0
sum:    dd 0

; Each hidden record is:
;   activation byte, padding byte,
;   bias word,
;   x weight, y weight, radius weight, constant-input weight
;
; Try changing ONE number, rebuilding, and observing the image. That is a much
; friendlier first experiment than altering the evaluator. Large weights make a
; feature dominate; signs reverse its influence; activations alter the geometry.
hidden_nodes:
    db ACT_ABS,0    
    dw -40, 90,-35,70,20
    db ACT_TENT,0
    dw 20,-80,100,40,-10
    db ACT_SQUARE,0
    dw -90,55,75,-30,80
    db ACT_LINEAR,0
    dw 10,110,15,-75,25
    db ACT_STEP,0
    dw -20,-45,95,60,-40
    db ACT_ABS,0
    dw 80,25,-105,50,35

output_node:
    ; Same record concept, but now there are six weights because the inputs are
    ; the six hidden-node results. eval_node knows the count from CX, not from
    ; the record itself.
    db ACT_LINEAR,0
    dw 0, 75,-55,90,45,-70,65

; =============================================================================
; Suggested experiments (change one thing, rebuild, observe, then undo)
; =============================================================================
; 1. Change one output weight's sign. This is the safest first modification.
; 2. Change one hidden activation ID, e.g. ACT_ABS to ACT_TENT.
; 3. Zero every output weight except one to see that hidden node by itself.
; 4. Replace radius=abs(x)+abs(y) with just abs(x) and observe lost symmetry.
; 5. Change the output mapping from SAR AX,1 to SAR AX,2. Predict the palette
;    index range before running it.
; 6. Temporarily replace STOSB with MOV AL,42 / STOSB. If the screen becomes one
;    color, the loader, video mode, palette, and framebuffer loop all work; the
;    remaining bug must be in network math.
; 7. Put `jmp $` immediately after INT 10h, then move it downward one subsystem
;    at a time. This primitive "binary search through execution" is genuinely
;    useful when no debugger or text console is available.
;
; A good bare-metal habit: preserve one known-working checkpoint. Change only
; one boundary at a time, and decide what visible result would prove that the
; boundary worked before writing the change.
