"use strict";

const W = 320, H = 200, Q = 256;
const canvas = document.querySelector("#screen");
const ctx = canvas.getContext("2d", { alpha: false });
const image = ctx.createImageData(W, H);
const inspectEl = document.querySelector("#inspect");
const statusEl = document.querySelector("#status");
const acts = ["linear", "abs", "square", "tent", "step"];
let generation = 0, rngState = 0xC0DE1234 >>> 0, timer = null;

// Each row is [activation index, bias, weight from input/node 0, ...].
// Weights are signed bytes; signals and biases are Q8 integers.
let layers;

function initialNetworkOld() {
  return [
    [[1,-40, 90,-35, 70, 20],[3,20,-80,100,40,-10],[2,-90,55,75,-30,80],
     [0,10,110,15,-75,25],[4,-20,-45,95,60,-40],[1,80,25,-105,50,35]],
    [[3,10,55,-20,80,15,-60,35],[2,-30,-70,45,20,90,30,-55],
     [1,40,25,65,-85,30,75,20],[0,-10,90,-40,35,-65,25,70],
     [3,70,-35,85,15,45,-75,25],[2,-50,60,20,-45,75,35,-80]],
    [[0,0,75,-55,90,45,-70,65]]
  ].map(layer => layer.map(row => row.slice()));
}

function initialNetwork() {
    const randInt = (min, max) =>
        Math.floor(Math.random() * (max - min + 1)) + min;

    // [activation, bias, ...weights]
    function node(numInputs) {
        return [
            // randInt(0, 4),       // activation function
            1, 
            randInt(-128, 127), // bias
            ...Array.from(
                { length: numInputs },
                () => randInt(-128, 127)
            )
        ];
    }

    return [
        // Layer 1: 4 inputs (x, y, radius, Q), 6 nodes
        Array.from({ length: 6 }, () => node(4)),

        // Layer 2: 6 inputs from layer 1, 6 nodes
        Array.from({ length: 6 }, () => node(6)),

        // Output layer: 6 inputs from layer 2, 1 node
        Array.from({ length: 1 }, () => node(6))
    ];

}
const clamp = (v, lo=-256, hi=255) => Math.max(lo, Math.min(hi, v | 0));

function activate(kind, x) {
  x = clamp(x);
  if (kind === 0) return x;
  if (kind === 1) return Math.abs(x);
  if (kind === 2) return clamp((x * x) >> 8, 0, 255);
  if (kind === 3) return 255 - Math.abs(x);
  return x >= 0 ? 255 : -256;
}

function evaluate(px, py, trace=false) {
  const x = (((px * 511) / (W - 1)) | 0) - 256;
  const y = (((py * 511) / (H - 1)) | 0) - 256;
  const radius = clamp(Math.abs(x) + Math.abs(y), 0, 255);
  let values = [x, y, radius, Q];
  const log = trace ? [`pixel (${px}, ${py})`, `input x=${x} y=${y} manhattan_r=${radius} bias=${Q}`] : null;

  layers.forEach((layer, li) => {
    const next = layer.map((node, ni) => {
      let sum = node[1];
      for (let i = 0; i < values.length; i++) sum += (node[i + 2] * values[i]) >> 8;
      const out = activate(node[0], sum);
      if (trace) log.push(`L${li + 1}N${ni}: ${acts[node[0]]}(${sum}) = ${out}`);
      return out;
    });
    values = next;
  });
  const index = clamp((values[0] + 256) >> 1, 0, 255);
  if (trace) log.push(`palette index = clamp((${values[0]} + 256) >> 1) = ${index}`);
  return trace ? { index, log } : index;
}

// A vivid 3-3-2 RGB palette: exactly 256 addressable entries, like a VGA DAC table.
function palette(index) {
  const r = ((index >> 5) & 7) * 255 / 7;
  const g = ((index >> 2) & 7) * 255 / 7;
  const b = (index & 3) * 255 / 3;
  return [r | 0, g | 0, b | 0];
}

function render() {
  let checksum = 2166136261 >>> 0;
  for (let y = 0, p = 0; y < H; y++) for (let x = 0; x < W; x++, p += 4) {
    const index = evaluate(x, y), rgb = palette(index);
    image.data[p] = rgb[0]; image.data[p + 1] = rgb[1]; image.data[p + 2] = rgb[2]; image.data[p + 3] = 255;
    checksum = Math.imul(checksum ^ index, 16777619) >>> 0;
  }
  ctx.putImageData(image, 0, 0);
  statusEl.textContent = `generation ${generation} · PRNG 0x${rngState.toString(16).padStart(8,"0")} · index checksum 0x${checksum.toString(16).padStart(8,"0")}`;
}

function random32() {
  let x = rngState;
  x ^= x << 13; x ^= x >>> 17; x ^= x << 5;
  return rngState = x >>> 0;
}

function evolve() {
  const edits = 1 + (random32() & 3);
  for (let e = 0; e < edits; e++) {
    const li = random32() % layers.length;
    const ni = random32() % layers[li].length;
    const node = layers[li][ni];
    if (li < 2 && (random32() & 31) === 0) node[0] = random32() % acts.length;
    else {
      const wi = 1 + (random32() % (node.length - 1));
      const delta = ((random32() % 17) | 0) - 8;
      node[wi] = clamp(node[wi] + delta, -128, 127);
    }
  }
  generation++;
  render();
}

document.querySelector("#mutate").onclick = evolve;
document.querySelector("#animate").onclick = function () {
  if (timer) { clearInterval(timer); timer = null; this.textContent = "Start evolution"; }
  else { timer = setInterval(evolve, 350); this.textContent = "Pause evolution"; }
};
document.querySelector("#reset").onclick = () => {
  layers = initialNetwork(); generation = 0; rngState = 0xC0DE1234 >>> 0; render();
};
canvas.onclick = event => {
  const box = canvas.getBoundingClientRect();
  const x = clamp(((event.clientX - box.left) * W / box.width) | 0, 0, W - 1);
  const y = clamp(((event.clientY - box.top) * H / box.height) | 0, 0, H - 1);
  inspectEl.textContent = evaluate(x, y, true).log.join("\n");
};

layers = initialNetwork();
render();
