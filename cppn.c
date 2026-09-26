
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

struct Node {
    u8 activation;
    u8 padding;                 /* naturally align the following 16-bit fields */
    s16 bias;
    s16 weight[HIDDEN_COUNT];
};


static struct Node hidden_nodes[HIDDEN_COUNT] = {
    { ACT_LINEAR,    0, -40, {  90,  -35,  70,  20,   0,   0 } },
    { ACT_LINEAR,   0,  20, { -80,  100,  40, -10,   0,   0 } },
    { ACT_LINEAR, 0, -90, {  55,   75, -30,  80,   0,   0 } },
    { ACT_LINEAR, 0,  10, { 110,   15, -75,  25,   0,   0 } },
    { ACT_LINEAR,   0, -20, { -45,   95,  60, -40,   0,   0 } },
    { ACT_LINEAR,    0,  80, {  25, -105,  50,  35,   0,   0 } }
};

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

    return (s16)clamp_s32(value, -256, 255);
}

static s16 evaluate_node(const struct Node *node, const s16 *input, u32 count)
{
    s32 sum = node->bias;
    u32 edge;

    for (edge = 0; edge < count; ++edge)
        sum += ((s32)input[edge] * (s32)node->weight[edge]) >> 8;

    return activate(node->activation, sum);
}


static u8 evaluate_pixel(u32 x, u32 y)
{
    s16 input[INPUT_COUNT];
    s16 hidden[HIDDEN_COUNT];
    s32 radius, output;
    u32 node;

    input[0] = (s16)((s32)(x * 511u) / 319 - 256);
    input[1] = (s16)((s32)(y * 511u) / 199 - 256);
    radius = absolute_s32(input[0]) + absolute_s32(input[1]);
    input[2] = (s16)clamp_s32(radius, 0, 255);
    input[3] = Q8_ONE;           /* constant bias input */

    for (node = 0; node < HIDDEN_COUNT; ++node)
        hidden[node] = evaluate_node(&hidden_nodes[node], input, INPUT_COUNT);

    output = evaluate_node(&output_node, hidden, HIDDEN_COUNT);
    return (u8)clamp_s32((output + 256) >> 1, 0, 255);
}

static void render_frame(void)
{
    u32 x, y, offset = 0;
    for (y = 0; y < SCREEN_HEIGHT; ++y)
        for (x = 0; x < SCREEN_WIDTH; ++x)
            framebuffer[offset++] = evaluate_pixel(x, y);
}


static inline void output_byte_to_port(u16 port, u8 value)
{
    __asm__ volatile ("outb %0, %1" : : "a"(value), "d"(port));
}

static void install_palette(void)
{
    u32 index;
    output_byte_to_port(0x3C8, 0);

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

/* Tiny deterministic PRNG */
static u32 random_u32(void)
{
    u32 value = random_state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return random_state = value;
}

static void mutate_network(void)
{
    u32 edit, edits = 1u + (random_u32() & 3u);

    for (edit = 0; edit < edits; ++edit) {
        struct Node *node = &hidden_nodes[random_u32() % HIDDEN_COUNT];
        u32 slot = random_u32() % (INPUT_COUNT + 1u);
        s32 delta = (s32)(random_u32() % 17u) - 8;
        s16 *parameter = slot == 0 ? &node->bias : &node->weight[slot - 1];
        *parameter = (s16)clamp_s32((s32)*parameter + delta, -128, 127);
        
    }

    /* Occasionally change how strongly one hidden feature reaches the output. */
    if ((random_u32() & 3u) == 0u) {
        u32 edge = random_u32() % HIDDEN_COUNT;
        s32 delta = (s32)(random_u32() % 17u) - 8;
        output_node.weight[edge] =
            (s16)clamp_s32((s32)output_node.weight[edge] + delta, -128, 127);
    }
}


static void pause_between_generations(void)
{
    volatile u32 counter;
    for (counter = 0; counter < 12000000u; ++counter)
        __asm__ volatile ("pause");
}

void cppn_main(void)
{
    install_palette();
    for (;;) {
        render_frame();
        // pause_between_generations();
        mutate_network();
    }
}

