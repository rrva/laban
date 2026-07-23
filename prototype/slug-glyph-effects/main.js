// PROTOTYPE — throwaway. Plan: "Three tunings of the per-glyph keystroke-impulse
// effect, switchable via ?variant=A|B|C."
//
// Fidelity targets (ported, not reinvented):
//   - Sources/LabanCore/GlyphEffectTimeline.swift      → ./timeline.js (same constants)
//   - Sources/LabanRenderer/VectorGlyphShaders.metal    → GLSL below (slugGlyphEvaluateEffect mirror)
//   - execplans/active/per-glyph-animation-channel.md   → kind 1 (keystroke impulse), kind 2 (bell shake)
//   - ADR 0018 idle park                               → rAF loop stops when nothing is live (HUD: link: PARKED)
//
// three-slug notes: SlugGeometry is an InstancedBufferGeometry; the per-glyph
// animation channel rides two extra instanced attributes (aEffect = kind,start;
// aGlyphColor) — the analogue of SlugGlyphInstance.effectKind/effectStart.
// injectSlug() owns material.onBeforeCompile, so we wrap it and splice our
// chunks into the slug chunks' tail anchors.

import * as THREE from 'three';
import { SlugGenerator, SlugGeometry, injectSlug } from 'three-slug';
import * as TL from './timeline.js';

// ---------------------------------------------------------------------------
// Variants — A is the plan contract; its uniforms are fed straight from
// timeline.js, so A is exactly GlyphEffectTimeline's constants.
// ---------------------------------------------------------------------------
const VARIANTS = {
  A: {
    label: 'A — plan contract (easeOutBack, exact constants)',
    scaleX: TL.keystrokeImpulseInitialScaleX,   // 0.55
    scaleY: TL.keystrokeImpulseInitialScaleY,   // 1.10
    tilt: TL.keystrokeImpulseInitialTilt,       // 0.07
    decay: TL.keystrokeImpulseDecaySeconds,     // 0.130
    c1: TL.easeOutBackC1, c3: TL.easeOutBackC3, // 1.70158 / 2.70158
    easeMode: 0,                                // 0 = easeOutBack
    bellAmplitudePx: 8,
    bellEvery: 0,                               // auto-demo: never auto-bell
  },
  B: {
    label: 'B — subtle (easeOutCubic, no overshoot, reduced tilt)',
    scaleX: 0.78, scaleY: 1.04, tilt: 0.025, decay: 0.110,
    c1: 0, c3: 0, easeMode: 1,                  // 1 = easeOutCubic
    bellAmplitudePx: 5,
    bellEvery: 0,
  },
  C: {
    label: 'C — punchy impulse + bell showcase',
    scaleX: 0.40, scaleY: 1.28, tilt: 0.12, decay: 0.170,
    c1: 2.30, c3: 3.30, easeMode: 0,
    bellAmplitudePx: 14,
    bellEvery: 4,                               // auto-demo: bell every 4th line
  },
};
const VARIANT_KEYS = Object.keys(VARIANTS);
const variantKey = new URLSearchParams(location.search).get('variant');
const variant = VARIANTS[variantKey] ?? VARIANTS.A;

// ---------------------------------------------------------------------------
// Settings (mirror the app's glyphEffectsEnabled + reduceMotion force-off)
// ---------------------------------------------------------------------------
const state = {
  effectsEnabled: true, // prototype defaults ON so the effect is visible; app ships default-off
  reduceMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
  autoDemo: false,
  liveCount: 0,
};

// ---------------------------------------------------------------------------
// Renderer / scene — orthographic, y-up, world units = CSS px
// ---------------------------------------------------------------------------
const renderer = new THREE.WebGLRenderer({ antialias: false });
renderer.setPixelRatio(devicePixelRatio);
renderer.setSize(innerWidth, innerHeight);
renderer.setClearColor(0x0d1117, 1);
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.OrthographicCamera(0, innerWidth, innerHeight, 0, -1, 1);

// ---------------------------------------------------------------------------
// GLSL — mirror of slugGlyphEvaluateEffect (VectorGlyphShaders.metal) + the
// M2 bell shake from GlyphEffectTimeline.bellShakeNormalizedOffset.
// Kind constants live in uniforms so variants switch without a shader rebuild;
// variant A's uniform values ARE the Metal constants.
// ---------------------------------------------------------------------------
const EFFECT_PARS_VERTEX = /* glsl */ `
in vec2 aEffect;      // x = effectKind, y = effectStart (seconds) — the animation channel
in vec3 aGlyphColor;
out vec3 vGlyphColor;
uniform float uTimeSeconds;
uniform vec4 uImpulse;   // initialScaleX, initialScaleY, initialTilt, decaySeconds
uniform vec3 uEaseBack;  // c1, c3, easeMode (0 = easeOutBack, 1 = easeOutCubic)
uniform float uBellAmplitudePx;
uniform float uBellDirection;
`;

// Runs right after three-slug's slug_vertex computes `transformed`
// (= px = originPx + unit * sizePx; aScaleBias.zw is the quad center, the
// Metal pivot `originPx + sizePx * 0.5`). Guards mirror the Metal early-return:
// no arithmetic runs for kind 0 or age >= decay, so settled glyphs are
// bit-identical to no effect.
const EFFECT_VERTEX = /* glsl */ `
{
  float kind = aEffect.x;
  float age = uTimeSeconds - aEffect.y;
  if (kind > 0.5 && kind < 1.5) {
    // Kind 1 — keystroke impulse. Mirrors slugGlyphEvaluateEffect's kind-1 branch.
    if (age < uImpulse.w) {
      float p;
      if (age <= 0.0) {
        p = 0.0;
      } else if (uEaseBack.z > 0.5) {
        float inv = 1.0 - age / uImpulse.w;   // easeOutCubic (variant B)
        p = 1.0 - inv * inv * inv;
      } else {
        float y = age / uImpulse.w - 1.0;     // easeOutBack (plan contract)
        p = 1.0 + uEaseBack.y * y * y * y + uEaseBack.x * y * y;
      }
      float sx = mix(uImpulse.x, 1.0, p);
      float sy = mix(uImpulse.y, 1.0, p);
      float theta = uImpulse.z * (1.0 - p);
      // Scale then rotate around the glyph quad's own center (Metal ordering).
      vec2 center = aScaleBias.zw;
      vec2 local = (transformed.xy - center) * vec2(sx, sy);
      float s = sin(theta);
      float c = cos(theta);
      transformed.xy = center + vec2(c * local.x - s * local.y,
                                     s * local.x + c * local.y);
    }
  } else if (kind > 1.5 && kind < 2.5) {
    // Kind 2 — bell shake. Critically damped x(t) = ωt·e^(1−ωt),
    // omega = 5 / 0.300 (GlyphEffectTimeline.bellShakeOmega).
    if (age > 0.0 && age < ${TL.bellShakeDecaySeconds.toFixed(3)}) {
      float phase = ${TL.bellShakeOmega.toFixed(7)} * age;
      transformed.x += uBellAmplitudePx * uBellDirection * phase * exp(1.0 - phase);
    }
  }
}
vGlyphColor = aGlyphColor;
`;

// ---------------------------------------------------------------------------
// Font → slug data → mesh
// ---------------------------------------------------------------------------
const generator = new SlugGenerator();
const slugData = await generator.generateFromUrl('./JetBrainsMono-Regular.ttf');

const FONT_PX = 16;
const fontScale = FONT_PX / slugData.unitsPerEm;
const advance = slugData.codePoints.get(0x4d).advanceWidth; // 'M' — JetBrains Mono is strictly monospace
const CELL_W = advance * fontScale;
const CELL_H = Math.round(FONT_PX * 1.25);
const ASCENT_PX = slugData.ascender * fontScale;
const MARGIN_X = 14;
const MARGIN_TOP = 70; // stay clear of the HUD (3 lines)

const MAX_GLYPHS = 8192;
const geometry = new SlugGeometry(MAX_GLYPHS);
const aColor = new Float32Array(MAX_GLYPHS * 3);
const aEffect = new Float32Array(MAX_GLYPHS * 2);
geometry.setAttribute('aGlyphColor', new THREE.InstancedBufferAttribute(aColor, 3).setUsage(THREE.DynamicDrawUsage));
geometry.setAttribute('aEffect', new THREE.InstancedBufferAttribute(aEffect, 2).setUsage(THREE.DynamicDrawUsage));

const material = new THREE.MeshBasicMaterial({ color: 0xffffff });
const mesh = new THREE.Mesh(geometry, material);
mesh.frustumCulled = false;
scene.add(mesh);
injectSlug(mesh, material, slugData);

// injectSlug assigned material.onBeforeCompile — wrap it and splice our chunks
// onto the tail anchors of the slug chunks.
const uniforms = {
  uTimeSeconds: { value: 0 },
  uImpulse: { value: new THREE.Vector4(variant.scaleX, variant.scaleY, variant.tilt, variant.decay) },
  uEaseBack: { value: new THREE.Vector3(variant.c1, variant.c3, variant.easeMode) },
  uBellAmplitudePx: { value: variant.bellAmplitudePx },
  uBellDirection: { value: 1 },
};
const slugOnBeforeCompile = material.onBeforeCompile;
material.onBeforeCompile = (shader) => {
  slugOnBeforeCompile(shader);
  Object.assign(shader.uniforms, uniforms);

  shader.vertexShader = shader.vertexShader
    .replace('flat out uvec4 vBandMaxTexCoords;', 'flat out uvec4 vBandMaxTexCoords;\n' + EFFECT_PARS_VERTEX)
    .replace('vBandMaxTexCoords = uvec4(aBandMaxTexCoords);',
             'vBandMaxTexCoords = uvec4(aBandMaxTexCoords);\n' + EFFECT_VERTEX);

  shader.fragmentShader = shader.fragmentShader
    .replace('precision highp usampler2D;', 'precision highp usampler2D;\nin vec3 vGlyphColor;')
    .replace('#include <color_fragment>', '#include <color_fragment>\n  diffuseColor.rgb *= vGlyphColor;');
};
material.customProgramCacheKey = () => 'slug-glyph-effects-prototype';

// ---------------------------------------------------------------------------
// Terminal content model — lines of cells; each cell carries its animation
// channel payload {kind, start}. Layout is an exact cell grid (monospace).
// ---------------------------------------------------------------------------
const C = {
  fg: new THREE.Color(0xc9d1d9), dim: new THREE.Color(0x8b949e),
  green: new THREE.Color(0x3fb950), blue: new THREE.Color(0x58a6ff),
  yellow: new THREE.Color(0xd29922), red: new THREE.Color(0xf85149),
  magenta: new THREE.Color(0xbc8cff),
};
const lines = []; // { cells: [{ch, color, kind, start}] }

const clockSeconds = () => performance.now() / 1000;

function maxRows() {
  return Math.max(4, Math.floor((innerHeight - MARGIN_TOP - 48) / CELL_H));
}

function pushLine(segs, { kind = TL.KIND_NONE, start = 0 } = {}) {
  const cells = [];
  for (const { text, color } of segs) {
    for (const ch of text) cells.push({ ch, color, kind, start });
  }
  lines.push({ cells });
  while (lines.length > maxRows()) lines.shift();
  return lines[lines.length - 1];
}

function rebuildGeometry() {
  geometry.clear();
  let gi = 0;
  const gate = (kind) =>
    (state.effectsEnabled && !state.reduceMotion) ? kind : TL.KIND_NONE; // GlyphEffectTimeline.effectiveKind + setting
  for (let row = 0; row < lines.length; row++) {
    // y of the baseline in y-up world coords: top of cell minus ascent
    const cellTop = innerHeight - MARGIN_TOP - row * CELL_H;
    const baseY = cellTop - ASCENT_PX;
    const { cells } = lines[row];
    for (let col = 0; col < cells.length; col++) {
      const cell = cells[col];
      if (cell.ch === ' ') continue;
      const data = slugData.codePoints.get(cell.ch.codePointAt(0)) ?? slugData.codePoints.get(-1);
      if (!data || data.width <= 0 || data.height <= 0) continue;
      if (gi >= MAX_GLYPHS) break;
      const x = MARGIN_X + col * CELL_W + data.bearingX * fontScale;
      const y = baseY + data.bearingY * fontScale;
      geometry.addGlyph(data, x, y, data.width * fontScale, data.height * fontScale, 0, 0);
      aColor[gi * 3] = cell.color.r; aColor[gi * 3 + 1] = cell.color.g; aColor[gi * 3 + 2] = cell.color.b;
      aEffect[gi * 2] = gate(cell.kind); aEffect[gi * 2 + 1] = cell.start;
      gi++;
    }
  }
  geometry.attributes.aGlyphColor.needsUpdate = true;
  geometry.attributes.aEffect.needsUpdate = true;
  // SlugGeometry.addGlyph() writes aScaleBias/aGlyphBandScale/aBandMaxTexCoords
  // on the CPU side but does NOT flag them for re-upload — only its own
  // addText() convenience path calls updateBuffers(). Skipping this call
  // leaves the GPU buffers frozen at whatever was last uploaded: new glyphs
  // render as zero-size (invisible), and on resize the existing glyphs stay
  // pinned at their old camera-space positions while the camera moves.
  geometry.updateBuffers();
  geometry.instanceCount = gi;
}

// ---------------------------------------------------------------------------
// ADR 0018 parking mirror — the rAF loop only runs while an effect is live
// (or a frame was explicitly requested). Parked = zero advanceFrames.
// ---------------------------------------------------------------------------
let running = false;

function countLive(now) {
  let n = 0;
  if (state.effectsEnabled && !state.reduceMotion) {
    for (const { cells } of lines)
      for (const cell of cells)
        if (cell.kind !== TL.KIND_NONE && TL.isAnimating(cell.kind, now - cell.start)) n++;
  }
  return n;
}

function kick() {
  if (!running) {
    running = true;
    requestAnimationFrame(tick);
  }
}

function tick() {
  const now = performance.now() / 1000;
  uniforms.uTimeSeconds.value = now;
  renderer.render(scene, camera);

  state.liveCount = countLive(now);
  if (state.liveCount > 0) {
    requestAnimationFrame(tick);
  } else {
    running = false; // parked — mirror of updateDisplayLinkRunState()
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
function stampLine(line, kind) {
  const now = clockSeconds();
  for (const cell of line.cells) { cell.kind = kind; cell.start = now; }
  rebuildGeometry();
  kick();
}

const OUT_POOL = [
  [{ text: 'total 48', color: C.fg }],
  [{ text: 'drwxr-xr-x  8 rrj staff   256 Jul 22 09:12 ', color: C.dim }, { text: 'Sources', color: C.blue }],
  [{ text: '-rw-r--r--  1 rrj staff  1821 Jul 22 09:12 ', color: C.dim }, { text: 'Package.swift', color: C.fg }],
  [{ text: '  ', color: C.fg }, { text: '47 passing', color: C.green }, { text: ' (812ms)', color: C.dim }],
  [{ text: 'On branch ', color: C.fg }, { text: 'main', color: C.magenta }],
  [{ text: 'nothing to commit, working tree clean', color: C.dim }],
  [{ text: 'warning: ', color: C.yellow }, { text: 'unused variable ‘spill’', color: C.fg }],
  [{ text: 'error: ', color: C.red }, { text: 'build failed (simulated, relax)', color: C.dim }],
  [{ text: '[slug] 2674 glyphs packed, 16 bands/glyph', color: C.dim }],
  [{ text: 'hello from the per-glyph animation channel', color: C.fg }],
];
let poolIdx = 0;
let autoLineCount = 0;

function typeLine() {
  const segs = OUT_POOL[poolIdx++ % OUT_POOL.length];
  const line = pushLine(segs);
  stampLine(line, TL.KIND_KEYSTROKE_IMPULSE);
  autoLineCount++;
  if (variant.bellEvery > 0 && autoLineCount % variant.bellEvery === 0) fireBell();
}

const CMD_POOL = ['git log --oneline -3', 'ls -la Sources', 'npm test', 'printf "hello\\n"'];
let cmdIdx = 0;
let typing = false;

function keystrokeDemo() {
  if (typing) return;
  typing = true;
  const cmd = CMD_POOL[cmdIdx++ % CMD_POOL.length];
  const line = pushLine([{ text: '$ ', color: C.green }]);
  let i = 0;
  const step = () => {
    if (i < cmd.length) {
      line.cells.push({ ch: cmd[i], color: C.fg, kind: TL.KIND_KEYSTROKE_IMPULSE, start: clockSeconds() });
      i++;
      rebuildGeometry();
      kick();
      setTimeout(step, 24 + Math.random() * 36);
    } else {
      typing = false;
      setTimeout(() => {
        const out = pushLine([{ text: `(ran '${cmd}')`, color: C.dim }]);
        stampLine(out, TL.KIND_KEYSTROKE_IMPULSE);
      }, 260);
    }
  };
  step();
}

let bellDir = 1;
function fireBell() {
  bellDir = -bellDir;
  uniforms.uBellDirection.value = bellDir;
  const now = clockSeconds();
  for (const { cells } of lines)
    for (const cell of cells) { cell.kind = TL.KIND_BELL_SHAKE; cell.start = now; }
  rebuildGeometry();
  kick();
}

let autoTimer = 0;
function toggleAuto() {
  state.autoDemo = !state.autoDemo;
  clearInterval(autoTimer);
  if (state.autoDemo) autoTimer = setInterval(typeLine, 850);
  updateButtons();
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);
function updateButtons() {
  $('btn-auto').textContent = `auto-demo: ${state.autoDemo ? 'on' : 'off'}`;
  $('btn-effects').textContent = `effects: ${state.effectsEnabled ? 'on' : 'off'}`;
  $('btn-motion').textContent = `reduceMotion: ${state.reduceMotion ? 'on' : 'off'}`;
  $('btn-effects').classList.toggle('off', !state.effectsEnabled);
  $('btn-motion').classList.toggle('off', state.reduceMotion);
}

$('btn-type').onclick = typeLine;
$('btn-keys').onclick = keystrokeDemo;
$('btn-bell').onclick = fireBell;
$('btn-auto').onclick = toggleAuto;
$('btn-effects').onclick = () => { state.effectsEnabled = !state.effectsEnabled; rebuildGeometry(); updateButtons(); kick(); };
$('btn-motion').onclick = () => { state.reduceMotion = !state.reduceMotion; rebuildGeometry(); updateButtons(); kick(); };

// Variant switcher (?variant=A|B|C, reload-stable/shareable)
const curKey = VARIANT_KEYS.includes(variantKey) ? variantKey : 'A';
document.getElementById('var-label').textContent = variant.label;
function cycleVariant(dir) {
  const i = VARIANT_KEYS.indexOf(curKey);
  const next = VARIANT_KEYS[(i + dir + VARIANT_KEYS.length) % VARIANT_KEYS.length];
  const params = new URLSearchParams(location.search);
  params.set('variant', next);
  location.search = params.toString();
}
document.getElementById('var-prev').onclick = () => cycleVariant(-1);
document.getElementById('var-next').onclick = () => cycleVariant(1);

addEventListener('keydown', (e) => {
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
  if (e.key === 'ArrowLeft') cycleVariant(-1);
  else if (e.key === 'ArrowRight') cycleVariant(1);
  else if (e.key === 'b' || e.key === 'B') fireBell();
  else if (e.key === 't' || e.key === 'T') typeLine();
  else if (e.key === 'k' || e.key === 'K') keystrokeDemo();
  else if (e.key === 'a' || e.key === 'A') toggleAuto();
  else if (e.key === 'e' || e.key === 'E') $('btn-effects').click();
  else if (e.key === 'm' || e.key === 'M') $('btn-motion').click();
});

addEventListener('resize', () => {
  renderer.setSize(innerWidth, innerHeight);
  camera.right = innerWidth;
  camera.top = innerHeight;
  camera.updateProjectionMatrix();
  while (lines.length > maxRows()) lines.shift();
  rebuildGeometry();
  kick();
});

// ---------------------------------------------------------------------------
// Seed a settled terminal (kind 0 — parked on load, mirroring the app's idle state)
// ---------------------------------------------------------------------------
pushLine([{ text: '$ ', color: C.green }, { text: 'ls -la', color: C.fg }]);
pushLine([{ text: 'total 48', color: C.fg }]);
pushLine([{ text: 'drwxr-xr-x  8 rrj staff   256 Jul 22 09:12 ', color: C.dim }, { text: 'Sources', color: C.blue }]);
pushLine([{ text: '-rw-r--r--  1 rrj staff  1821 Jul 22 09:12 ', color: C.dim }, { text: 'Package.swift', color: C.fg }]);
pushLine([{ text: '$ ', color: C.green }, { text: 'git status', color: C.fg }]);
pushLine([{ text: 'On branch ', color: C.fg }, { text: 'main', color: C.magenta }]);
pushLine([{ text: 'nothing to commit, working tree clean', color: C.dim }]);
pushLine([{ text: '$ ', color: C.green }]);

rebuildGeometry();
updateButtons();
document.getElementById('loading').remove();
kick(); // one demand render, then it parks

// Test-only hook for verify.mjs — nothing renders from this on screen. The
// visible page shows only what's being judged (the glyph effect itself); no
// live status readout, since a changing HUD next to the animation competes
// for attention with the thing being watched.
window.__testState = () => ({ running, liveCount: state.liveCount });
