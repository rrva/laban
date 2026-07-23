// PROTOTYPE — throwaway. Hover-to-preview tab overview.
//
// Sibling of ../tab-thumbnails, same underlying tech (flat orthographic
// camera, MeshBasicMaterial, geometry.addText(), no perspective/lighting/
// animation loop), different trade-off: instead of a small permanent strip
// on every row (always visible, but small and space-costly), a single
// reused floating panel is repositioned and populated on hover — bigger,
// more legible, and costs zero permanent sidebar space, at the price of
// needing a hover to see it at all.

import * as THREE from 'three';
import { SlugGenerator, SlugGeometry, injectSlug } from 'three-slug';

// ---------------------------------------------------------------------------
// Tab content — identical shape/content to ../tab-thumbnails.
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
const MAX_LINES_KEPT = 30;

const generator = new SlugGenerator();
const slugData = await generator.generateFromUrl('./JetBrainsMono-Regular.ttf');

const BG = 0x0d1117;
const TEXT_COLOR = 0xdbe4ff;

function truncate(line, maxChars) {
  return line.length > maxChars ? line.slice(0, maxChars - 3) + '...' : line;
}

// ---------------------------------------------------------------------------
// One reusable flat text-stage per canvas — identical to ../tab-thumbnails.
// ---------------------------------------------------------------------------
function createTextStage(canvas, { color, bg }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(devicePixelRatio);
  renderer.setClearColor(bg, 1);

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(0, 1, 1, 0, -1, 1);
  let textMesh = null;
  let h = 0;
  let lastArgs = null;

  function resize() {
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(1, Math.round(rect.width));
    h = Math.max(1, Math.round(rect.height));
    renderer.setSize(w, h);
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
  return { setLines, resize };
}

// ---------------------------------------------------------------------------
// Main stage — full size, borderless.
// ---------------------------------------------------------------------------
const mainCanvas = document.createElement('canvas');
mainCanvas.style.width = '100%';
mainCanvas.style.height = '100%';
document.querySelector('.stage').appendChild(mainCanvas);
const mainStage = createTextStage(mainCanvas, { color: TEXT_COLOR, bg: BG });

const MAIN_FONT_PX = 16;
const MAIN_MARGIN = 14;
const MAIN_LINES = 8;
const MAIN_MAX_CHARS = 100;

let currentIndex = 0;
function refreshMain() {
  mainStage.setLines(TABS[currentIndex].lines.slice(-MAIN_LINES), MAIN_FONT_PX, MAIN_MARGIN, MAIN_MAX_CHARS);
}

const tabRows = [...document.querySelectorAll('.tab-row')];
function updateSidebar() { tabRows.forEach((r, i) => r.classList.toggle('selected', i === currentIndex)); }
function switchCurrent(i) {
  if (i === currentIndex) return;
  currentIndex = i;
  refreshMain();
  updateSidebar();
  if (hoveredIndex === i) hidePreview(); // now redundant with the main view — see hover handlers below
}

// ---------------------------------------------------------------------------
// Floating hover preview — one reused panel + canvas, repositioned and
// repopulated on hover. Bigger than a row strip could afford: more lines,
// larger font, genuinely readable rather than a squint-worthy thumbnail.
// ---------------------------------------------------------------------------
const previewEl = document.querySelector('.preview');
const previewCanvas = previewEl.querySelector('canvas');
const previewStage = createTextStage(previewCanvas, { color: TEXT_COLOR, bg: BG });

// "Realistic scale," first pass: a true proportional miniature of the main
// view rather than independently-chosen numbers. PREVIEW_SCALE is applied
// uniformly to the main stage's own current width AND height (so the
// aspect ratio is identical by construction, not approximated) and to the
// font size, so the SAME character budget (MAIN_MAX_CHARS) that fits the
// main view at full size also fits the preview at small size — the
// preview shows exactly the content window the main view shows
// (`MAIN_LINES` lines), just uniformly shrunk, not an independently
// cropped or truncated subset. Trying "all of the content" (this) before
// a "lower half only" crop, per explicit instruction.
const PREVIEW_SCALE = 0.5;
const SHOW_DELAY_MS = 130; // avoids flashing the preview on a fast mouse pass-through

let hoveredIndex = null;
let showTimer = 0;
let previewGeom = null; // recomputed each time the preview is (re)shown, from the main stage's LIVE size

function computePreviewGeometry() {
  const mainRect = document.querySelector('.stage').getBoundingClientRect();
  return {
    width: mainRect.width * PREVIEW_SCALE,
    height: mainRect.height * PREVIEW_SCALE,
    fontPx: MAIN_FONT_PX * PREVIEW_SCALE,
    margin: MAIN_MARGIN * PREVIEW_SCALE,
  };
}

function refreshPreview() {
  if (hoveredIndex == null) return;
  previewStage.setLines(TABS[hoveredIndex].lines.slice(-MAIN_LINES), previewGeom.fontPx, previewGeom.margin, MAIN_MAX_CHARS);
}

function positionPreview(rowEl) {
  const sidebarRect = rowEl.closest('.sidebar').getBoundingClientRect();
  const rowRect = rowEl.getBoundingClientRect();
  let top = rowRect.top;
  // Keep the panel on-screen if the row is near the bottom of the viewport.
  top = Math.min(top, innerHeight - previewGeom.height - 12);
  top = Math.max(top, 12);
  previewEl.style.left = `${sidebarRect.right + 10}px`;
  previewEl.style.top = `${top}px`;
}

function showPreview(i, rowEl) {
  hoveredIndex = i;
  previewGeom = computePreviewGeometry();
  previewEl.style.width = `${previewGeom.width}px`;
  previewEl.style.height = `${previewGeom.height}px`;
  // Explicit synchronous resize rather than waiting on the canvas's own
  // ResizeObserver (async by spec) to notice the CSS size just changed —
  // getBoundingClientRect() inside resize() forces a layout flush, so this
  // is correct immediately, not just "correct a frame later."
  previewStage.resize();
  refreshPreview();
  positionPreview(rowEl);
  previewEl.classList.add('visible');
}
function hidePreview() {
  hoveredIndex = null;
  previewEl.classList.remove('visible');
}

tabRows.forEach((el, i) => {
  el.addEventListener('click', () => switchCurrent(i));
  el.addEventListener('mouseenter', () => {
    clearTimeout(showTimer);
    if (i === currentIndex) return; // redundant with the already-visible main view
    showTimer = setTimeout(() => showPreview(i, el), SHOW_DELAY_MS);
  });
  el.addEventListener('mouseleave', () => {
    clearTimeout(showTimer);
    hidePreview();
  });
});

refreshMain();
updateSidebar();

// A resize invalidates previewGeom (it's derived from the main stage's
// size) — simplest correct fix is to just close the preview rather than
// re-deriving position/size mid-hover; re-hovering shows it fresh at the
// new scale.
window.addEventListener('resize', () => { refreshMain(); hidePreview(); });

// ---------------------------------------------------------------------------
// Background activity simulation — identical cadence/shape to
// ../tab-thumbnails. Tabs keep "running" regardless of hover/current state;
// the preview (if open on a tab that just changed) and the main view (if
// showing the tab that just changed) refresh immediately.
// ---------------------------------------------------------------------------
setInterval(() => {
  for (let i = 0; i < TABS.length; i++) {
    const tab = TABS[i];
    if (!tab.feed.length || Math.random() >= 0.5) continue;
    tab.lines.push(tab.feed[tab.feedIdx % tab.feed.length]);
    tab.feedIdx++;
    if (tab.lines.length > MAX_LINES_KEPT) tab.lines.shift();
    if (i === currentIndex) refreshMain();
    if (i === hoveredIndex) refreshPreview();
  }
}, 1800);
