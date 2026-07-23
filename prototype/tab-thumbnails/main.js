// PROTOTYPE — throwaway. Always-on live tab thumbnails.
//
// No 3D, no perspective camera, no lighting — deliberately dropped from the
// last two prototypes, because this idea isn't about depth. It's about the
// one property genuinely exclusive to vector glyph rendering: a miniature
// representation of text stays perfectly crisp at any scale, because it's
// the same analytic curves being rasterized smaller, not a downscaled
// bitmap screenshot. Every sidebar row gets a small, permanent, live strip
// of that tab's own recent output — ambient awareness with zero
// interaction, replacing ../tab-peek-3d's hold-to-peek gesture.
//
// Uses geometry.addText() (three-slug's own convenience layout method,
// calls updateBuffers() internally) and a flat orthographic 1:1-CSS-pixel
// camera per canvas — the same simple setup as ../slug-glyph-effects, not
// the frustum-fitting math the two tilt/flip prototypes needed for
// perspective. No animation loop either: nothing here transitions, so each
// canvas just re-renders once, on demand, whenever its own content changes.

import * as THREE from 'three';
import { SlugGenerator, SlugGeometry, injectSlug } from 'three-slug';

// ---------------------------------------------------------------------------
// Tab content — same shape as ../tab-peek-3d: `lines` is the live buffer,
// `feed` is a repeating pool of plausible next-lines simulating background
// activity (`main` has none — nothing happens in the tab you're using).
// ---------------------------------------------------------------------------
const TABS = [
  { name: 'main', lines: [
      '$ git status', 'On branch spinner-motion-implementation',
      "Your branch is ahead of 'origin/...' by 29 commits.", '$ ',
    ], feed: [], feedIdx: 0 },
  { name: 'tests', lines: [
      '$ swift test --filter Slug', "Test Suite 'SlugTests' started",
    ], feed: [
      '  ok testGlyphCoverage (0.012s)', '  ok testBandPacking (0.031s)',
      '  ok testCurveTrace (0.024s)', '  ok testKindDispatch (0.008s)',
      '47 tests, 47 passed (0.812s)', '$ ',
    ], feedIdx: 0 },
  { name: 'build', lines: ['$ ./scripts/build-app'], feed: [
      '[1/212] Compiling LabanCore GlyphEffectTimeline.swift',
      '[89/212] Compiling LabanRenderer VectorGlyphShaders.metal',
      '[150/212] Compiling LabanApp TerminalBitmapView.swift',
      "warning: unused variable 'spill'",
      '[212/212] Build complete! (24.3s)', '$ ',
    ], feedIdx: 0 },
  { name: 'logs', lines: ['$ tail -f laban.log'], feed: [
      '[10:41:02] session attach ok (id=3536DD0D)',
      '[10:41:05] glyph-effects: parked (0 live)',
      '[10:41:09] control: GET /debug/state 200 4ms',
      '[10:41:14] session attach ok (id=1192228B)',
      '[10:41:20] display-link: park restored',
      '[10:41:27] control: GET /debug/health 200 1ms',
    ], feedIdx: 0 },
];
const MAX_LINES_KEPT = 30; // buffer cap per tab; only the tail is ever shown

const generator = new SlugGenerator();
const slugData = await generator.generateFromUrl('./JetBrainsMono-Regular.ttf');

const BG = 0x0d1117;
const TEXT_COLOR = 0xdbe4ff;
// Muted, not full-bright — this is meant to read as ambient background
// signal you can choose to look at, not something competing for attention
// with the main terminal. Directly answers the "might become visually
// fatiguing" concern from earlier in this exploration: quiet by default.
const STRIP_TEXT_COLOR = 0x717c94;
const STRIP_BG = 0x171822; // a touch lighter than the sidebar itself, reads as "a little terminal window" without a border

function truncate(line, maxChars) {
  return line.length > maxChars ? line.slice(0, maxChars - 3) + '...' : line;
}

// ---------------------------------------------------------------------------
// One reusable flat text-stage per canvas: orthographic camera in 1:1 CSS
// pixels (world x/y == canvas CSS x/y, y-up), no lighting, no perspective.
// ---------------------------------------------------------------------------
function createTextStage(canvas, { color, bg }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(devicePixelRatio);
  renderer.setClearColor(bg, 1);

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(0, 1, 1, 0, -1, 1);
  let textMesh = null;
  let h = 0;
  let lastArgs = null; // re-applied after a resize, since text position depends on canvas height

  function resize() {
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(1, Math.round(rect.width));
    h = Math.max(1, Math.round(rect.height));
    renderer.setSize(w, h); // updateStyle defaults true — see ../tab-flip-3d/NOTES.md for what skipping that does
    camera.left = 0; camera.right = w; camera.top = h; camera.bottom = 0;
    camera.updateProjectionMatrix();
    if (lastArgs) setLines(...lastArgs);
    else render();
  }

  function setLines(lines, fontPx, margin, maxChars) {
    lastArgs = [lines, fontPx, margin, maxChars];
    if (textMesh) {
      scene.remove(textMesh);
      textMesh.geometry.dispose();
      textMesh.material.dispose();
    }
    const text = lines.map((l) => truncate(l, maxChars)).join('\n');
    const fontScale = fontPx / slugData.unitsPerEm;
    const ascentPx = slugData.ascender * fontScale;
    const geometry = new SlugGeometry(Math.max(1, text.length));
    const material = new THREE.MeshBasicMaterial({ color });
    geometry.addText(text, slugData, { fontScale, startX: 0, startY: 0, justify: 'left' });
    textMesh = new THREE.Mesh(geometry, material);
    injectSlug(textMesh, material, slugData);
    textMesh.position.set(margin, h - margin - ascentPx, 0);
    scene.add(textMesh);
    render();
  }

  function render() { renderer.render(scene, camera); }

  new ResizeObserver(resize).observe(canvas);
  resize();
  return { setLines };
}

// ---------------------------------------------------------------------------
// Main stage — full size, borderless, fills its container. No card, no
// margin: this should read as "the terminal," not "a panel in a scene."
// ---------------------------------------------------------------------------
const mainCanvas = document.createElement('canvas');
document.querySelector('.stage').appendChild(mainCanvas);
const mainStage = createTextStage(mainCanvas, { color: TEXT_COLOR, bg: BG });

const MAIN_FONT_PX = 16;
const MAIN_MARGIN = 14;
const MAIN_LINES = 8;
const MAIN_MAX_CHARS = 100;

// ---------------------------------------------------------------------------
// Row strips — one per sidebar row, using the <canvas class="strip"> already
// in the DOM. Deliberately NOT the same aspect ratio as the main terminal:
// forcing that would mean either illegibly compressing the whole terminal
// into a short wide strip, or accepting clutter. Each strip instead shows
// only the "lower half" — the last few lines, closest to the live
// prompt/cursor, which is also the actually useful signal.
// ---------------------------------------------------------------------------
const STRIP_FONT_PX = 9;
const STRIP_MARGIN = 5;
const STRIP_LINES = 3;
const STRIP_MAX_CHARS = 34;

const rowStages = TABS.map((_, i) => {
  const canvas = document.querySelector(`canvas[data-strip="${i}"]`);
  return createTextStage(canvas, { color: STRIP_TEXT_COLOR, bg: STRIP_BG });
});

// ---------------------------------------------------------------------------
// Refresh + switching.
// ---------------------------------------------------------------------------
let currentIndex = 0;
function refreshMain() {
  mainStage.setLines(TABS[currentIndex].lines.slice(-MAIN_LINES), MAIN_FONT_PX, MAIN_MARGIN, MAIN_MAX_CHARS);
}
function refreshStrip(i) {
  rowStages[i].setLines(TABS[i].lines.slice(-STRIP_LINES), STRIP_FONT_PX, STRIP_MARGIN, STRIP_MAX_CHARS);
}
function refreshAllStrips() { for (let i = 0; i < TABS.length; i++) refreshStrip(i); }

const tabRows = [...document.querySelectorAll('.tab-row')];
function updateSidebar() { tabRows.forEach((r, i) => r.classList.toggle('selected', i === currentIndex)); }

function switchCurrent(i) {
  if (i === currentIndex) return;
  currentIndex = i;
  refreshMain();
  updateSidebar();
}
tabRows.forEach((el) => el.addEventListener('click', () => switchCurrent(Number(el.dataset.pane))));

refreshMain();
refreshAllStrips();
updateSidebar();

window.addEventListener('resize', () => { refreshMain(); refreshAllStrips(); });

// ---------------------------------------------------------------------------
// Background activity simulation — every tab keeps "running" whether you're
// looking at it or not. Unlike ../tab-peek-3d (where minis only refreshed
// while actively peeking), strips here refresh unconditionally and
// immediately — that's the entire point of "always on."
// ---------------------------------------------------------------------------
setInterval(() => {
  for (let i = 0; i < TABS.length; i++) {
    const tab = TABS[i];
    if (!tab.feed.length || Math.random() >= 0.5) continue;
    tab.lines.push(tab.feed[tab.feedIdx % tab.feed.length]);
    tab.feedIdx++;
    if (tab.lines.length > MAX_LINES_KEPT) tab.lines.shift();
    refreshStrip(i);
    if (i === currentIndex) refreshMain();
  }
}, 1800);
