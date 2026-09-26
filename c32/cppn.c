/* =============================================================================
 * cppn.c -- the algorithmic half of the bootable artwork
 * =============================================================================

/* Avoid host-library headers. These sizes are fixed by the 32-bit x86 ABI. */
typedef unsigned char  u8;
typedef unsigned short u16;
typedef signed short   s16;
typedef unsigned int   u32;
typedef signed int     s32;

enum {
    SCREEN_WIDTH = 320, SCREEN_HEIGHT = 200, PALETTE_SIZE = 256,
    Q8_ONE = 256, INPUT_COUNT = 4, HIDDEN_COUNT = 6
};

static volatile u8 *const framebuffer = (volatile u8 *)0xA0000;

enum Activation {
    ACT_LINEAR, ACT_ABS, ACT_SQUARE, ACT_TENT, ACT_STEP, ACTIVATION_COUNT
};

/* Q8 stores 1.0 as 256 and -0.5 as -128. A Q8*Q8 product is shifted right by
 * eight to restore Q8 scale. Six weight slots fit our largest (output) node. */
struct Node {
    u8 activation;
    u8 padding;                 /* naturally align the following 16-bit fields */
    s16 bias;
    s16 weight[HIDDEN_COUNT];
};

/* Initialized, writable .data: these bytes are loaded from floppy, then mutated
 * in RAM. Hidden nodes use only their first four weight slots. */
static struct Node hidden_nodes[HIDDEN_COUNT] = {
    { ACT_LINEAR,    0, -40, {  90,  -35,  70,  20,   0,   0 } },
    { ACT_LINEAR,   0,  20, { -80,  100,  40, -10,   0,   0 } },
    { ACT_LINEAR, 0, -90, {  55,   75, -30,  80,   0,   0 } },
    { ACT_LINEAR, 0,  10, { 110,   15, -75,  25,   0,   0 } },
    { ACT_LINEAR,   0, -20, { -45,   95,  60, -40,   0,   0 } },
    { ACT_LINEAR,    0,  80, {  25, -105,  50,  35,   0,   0 } }
};

/* Middle-ground color model: red and green use hidden nodes directly, while
 * blue retains a complete output node that mixes all six hidden features. */
static struct Node output_node = {
    ACT_LINEAR, 0, 0, { 75, -55, 90, 45, -70, 65 }
};

/* Explicit seed makes the mutation sequence repeat exactly after every boot. */
static u32 random_state = 0xC0DE1234u;

static s32 clamp_s32(s32 value, s32 low, s32 high)
{
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

static s32 absolute_s32(s32 value)
{
    return value < 0 ? -value : value;
}

/* Nonlinear activations create folds and regions. Purely linear layers would
 * collapse algebraically into one linear transform and make dull gradients. */
static s16 activate(u8 kind, s32 value)
{
    value = clamp_s32(value, -256, 255);

    switch (kind) {
    case ACT_LINEAR:                         break;
    case ACT_ABS:    value = absolute_s32(value); break;
    case ACT_SQUARE: value = (value * value) >> 8; break;
    case ACT_TENT:   value = 255 - absolute_s32(value); break;
    case ACT_STEP:
    default:         value = value >= 0 ? 255 : -256; break;
    }

    /* abs(-256) and square(-256) produce +256, requiring a second clamp. */
    return (s16)clamp_s32(value, -256, 255);
}

/* High-level equivalent of assembly's eval_node. Cast before multiplication so
 * the compiler performs a 32-bit product instead of overflowing at 16 bits. */
static s16 evaluate_node(const struct Node *node, const s16 *input, u32 count)
{
    s32 sum = node->bias;
    u32 edge;

    for (edge = 0; edge < count; ++edge)
        sum += ((s32)input[edge] * (s32)node->weight[edge]) >> 8;

    return activate(node->activation, sum);
}

/* Knows network topology, but knows nothing about VGA. Its complete contract is
 * coordinate in, palette index out. This separation makes host-side tests easy. */
static u8 evaluate_pixel(u32 x, u32 y)
{
    s16 input[INPUT_COUNT];
    s16 hidden[HIDDEN_COUNT];
    s32 radius;
    s16 blue_output;
    u8 red, green, blue;
    u32 node;

    /* Inclusive mapping: x=0 -> -256 and x=319 -> +255. Thirty-two-bit C makes
     * the direct multiply/divide safe, unlike our deliberately 16-bit ASM. */
    input[0] = (s16)((s32)(x * 511u) / 319 - 256);
    input[1] = (s16)((s32)(y * 511u) / 199 - 256);
    radius = absolute_s32(input[0]) + absolute_s32(input[1]);
    input[2] = (s16)clamp_s32(radius, 0, 255);
    input[3] = Q8_ONE;           /* constant bias input */

    for (node = 0; node < HIDDEN_COUNT; ++node)
        hidden[node] = evaluate_node(&hidden_nodes[node], input, INPUT_COUNT);

    /* Red and green expose two hidden features without extra weighted edges.
     * Blue is a full mixture of all six. All three are still generated inside
     * the CPPN evaluation; there is no later framebuffer-processing pass. */
    blue_output = evaluate_node(&output_node, hidden, HIDDEN_COUNT);

    red   = (u8)(((s32)hidden[0]   + 256) * 8 >> 9); /* 0..7 */
    green = (u8)(((s32)hidden[1]   + 256) * 8 >> 9); /* 0..7 */
    blue  = (u8)(((s32)blue_output + 256) * 4 >> 9); /* 0..3 */

    return (u8)((red << 5) | (green << 2) | blue);
}

static void render_frame(void)
{
    u32 x, y, offset = 0;
    for (y = 0; y < SCREEN_HEIGHT; ++y)
        for (x = 0; x < SCREEN_WIDTH; ++x)
            framebuffer[offset++] = evaluate_pixel(x, y);
}

/* ISO C has no OUT instruction. This tiny inline-assembly wrapper is an honest
 * hardware boundary: "a" selects AL and "d" selects DX for `outb AL,DX`. */
static inline void output_byte_to_port(u16 port, u8 value)
{
    __asm__ volatile ("outb %0, %1" : : "a"(value), "d"(port));
}

static void install_palette(void)
{
    u32 index;
    output_byte_to_port(0x3C8, 0);  /* begin changing DAC palette entry zero */

    for (index = 0; index < PALETTE_SIZE; ++index) {
        /* Interpret index as RRR GGG BB; VGA DAC channels range from 0..63. */
        u8 red   = (u8)(((index >> 5) & 7u) * 9u);
        u8 green = (u8)(((index >> 2) & 7u) * 9u);
        u8 blue  = (u8)(( index       & 3u) * 21u);
        output_byte_to_port(0x3C9, red);
        output_byte_to_port(0x3C9, green);
        output_byte_to_port(0x3C9, blue);
    }
}

/* Tiny deterministic PRNG: appropriate for repeatable art, not cryptography. */
static u32 random_u32(void)
{
    u32 value = random_state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return random_state = value;
}

/* -----------------------------------------------------------------------------
 * Persistent walk through network space
 * -----------------------------------------------------------------------------
 * The old mutation was a bounded random walk:
 *
 *     parameter += random(-8, +8); clamp(parameter, -128, 127)
 *
 * Its average movement was zero, so it naturally wandered back across places it
 * had recently visited. Clamping also made values loiter at the two boundaries.
 *
 * Here every mutable parameter gets a POSITION and a VELOCITY. Position has 24
 * useful bits. Its upper eight bits become the visible weight [-128,+127], while
 * its lower sixteen bits are a fractional position between adjacent weights:
 *
 *    phase bits:  PPPPPPPP ffffffffffffffff
 *                 visible   fractional
 *
 * Adding velocity every frame creates momentum. Unsigned arithmetic wraps at
 * 2^24, so +127 connects to -128 like opposite edges of a map: parameter space
 * is treated as a torus rather than a box with walls. We gently change speeds,
 * but never let a dimension stop or reverse. The combined network therefore
 * follows a long directed path instead of trembling around its starting point.
 */
enum {
    HIDDEN_WALK_PARAMETERS = INPUT_COUNT + 1, /* bias + four used weights */
    OUTPUT_WALK_PARAMETERS = HIDDEN_COUNT + 1,/* bias + six output weights */
    WALK_DIMENSIONS = HIDDEN_COUNT * HIDDEN_WALK_PARAMETERS
                    + OUTPUT_WALK_PARAMETERS,
    WALK_PHASE_MASK = 0x00ffffffu,
    WALK_MIN_SPEED = 32767,
    WALK_MAX_SPEED = 32767
};

/* These arrays are .bss state. entry.asm zeros them before C begins. They are
 * mutation's private coordinates and do not alter the Node/rendering skeleton. */
static u32 hidden_phase[HIDDEN_COUNT][HIDDEN_WALK_PARAMETERS];
static s16 hidden_velocity[HIDDEN_COUNT][HIDDEN_WALK_PARAMETERS];
static u32 output_phase[OUTPUT_WALK_PARAMETERS];
static s16 output_velocity[OUTPUT_WALK_PARAMETERS];
static u8 walk_initialized;

/* Bias is slot zero; the meaningful weights follow it. Keeping this mapping in
 * one helper prevents the walking code from knowing struct byte offsets. */
static s16 *hidden_parameter(u32 node, u32 slot)
{
    return slot == 0u
        ? &hidden_nodes[node].bias
        : &hidden_nodes[node].weight[slot - 1u];
}

static s16 *output_parameter(u32 slot)
{
    return slot == 0u
        ? &output_node.bias
        : &output_node.weight[slot - 1u];
}

/* Construct a phase whose visible byte exactly matches the existing parameter.
 * Random fractional bits stop all dimensions crossing integer boundaries at the
 * same moment. Velocity magnitude comes from WALK_MIN_SPEED..WALK_MAX_SPEED;
 * with both currently 32767, every dimension moves about 0.50 units per frame.
 * Making it odd gives good coverage of the power-of-two circular phase space. */
static void begin_dimension(s16 parameter, u32 *phase, s16 *velocity)
{
    u32 speed = WALK_MIN_SPEED
              + random_u32() % (WALK_MAX_SPEED - WALK_MIN_SPEED + 1u);

    speed |= 1u;
    *phase = ((((u32)((s32)parameter + 128)) & 255u) << 16)
           | (random_u32() & 0xffffu);
    *velocity = (random_u32() & 1u) ? (s16)speed : (s16)-(s32)speed;
}

static void initialize_walk(void)
{
    u32 node, slot;

    for (node = 0; node < HIDDEN_COUNT; ++node) {
        for (slot = 0; slot < HIDDEN_WALK_PARAMETERS; ++slot) {
            begin_dimension(*hidden_parameter(node, slot),
                            &hidden_phase[node][slot],
                            &hidden_velocity[node][slot]);
        }
    }

    for (slot = 0; slot < OUTPUT_WALK_PARAMETERS; ++slot) {
        begin_dimension(*output_parameter(slot),
                        &output_phase[slot],
                        &output_velocity[slot]);
    }

    walk_initialized = 1u;
}

/* Move one coordinate forward, wrap it on the 24-bit torus, and expose its top
 * byte as a signed-looking weight. Converting 0..255 to -128..127 explicitly is
 * clearer than depending on implementation-defined unsigned-to-signed casts. */
static void advance_dimension(u32 *phase, s16 velocity, s16 *parameter)
{
    u32 visible;

    *phase = (*phase + (u32)(s32)velocity) & WALK_PHASE_MASK;
    visible = (*phase >> 16) & 255u;
    *parameter = (s16)((s32)visible - 128);
}

/* Bend the path slightly by changing one dimension's speed. Its sign is kept,
 * so steering cannot reverse that coordinate and retrace the route it just took.
 * Minimum speed prevents any dimension from becoming visually frozen. */
static void steer_velocity(s16 *velocity)
{
    s32 change = (s32)(random_u32() % 513u) - 256;
    s32 next = (s32)*velocity + change;

    if (*velocity > 0) {
        next = clamp_s32(next, WALK_MIN_SPEED, WALK_MAX_SPEED);
    } else {
        next = clamp_s32(next, -WALK_MAX_SPEED, -WALK_MIN_SPEED);
    }

    /* Retain an odd speed, preserving the longest cycle through 2^24 states. */
    if ((next & 1) == 0)
        next += next > 0 ? 1 : -1;

    *velocity = (s16)next;
}

static void mutate_network(void)
{
    u32 node, slot, dimension;

    if (!walk_initialized)
        initialize_walk();

    /* Unlike sparse mutation, every coordinate advances. Because each has its
     * own phase, speed, and direction, this is not one line through the forest:
     * it is one trajectory through WALK_DIMENSIONS-dimensional network space. */
    for (node = 0; node < HIDDEN_COUNT; ++node) {
        for (slot = 0; slot < HIDDEN_WALK_PARAMETERS; ++slot) {
            advance_dimension(&hidden_phase[node][slot],
                              hidden_velocity[node][slot],
                              hidden_parameter(node, slot));
        }
    }

    for (slot = 0; slot < OUTPUT_WALK_PARAMETERS; ++slot) {
        advance_dimension(&output_phase[slot], output_velocity[slot],
                          output_parameter(slot));
    }

    /* Steer exactly one dimension each generation. Choosing from a flat index
     * keeps every bias and weight equally likely. With MIN_SPEED==MAX_SPEED,
     * steering intentionally has no effect; widening that range restores it. */
    dimension = random_u32() % WALK_DIMENSIONS;
    if (dimension < HIDDEN_COUNT * HIDDEN_WALK_PARAMETERS) {
        node = dimension / HIDDEN_WALK_PARAMETERS;
        slot = dimension % HIDDEN_WALK_PARAMETERS;
        steer_velocity(&hidden_velocity[node][slot]);
    } else {
        slot = dimension - HIDDEN_COUNT * HIDDEN_WALK_PARAMETERS;
        steer_velocity(&output_velocity[slot]);
    }
}

/* Crude CPU-work delay, not real time. QEMU and hardware will differ. A future
 * version can teach timer interrupts or VGA vertical-retrace synchronization. */
// static void pause_between_generations(void)
// {
//     volatile u32 counter;
//     for (counter = 0; counter < 12000000u; ++counter)
//         __asm__ volatile ("pause");
// }

void cppn_main(void)
{
    install_palette();
    for (;;) {
        render_frame();
        // pause_between_generations();
        mutate_network();
    }
}

