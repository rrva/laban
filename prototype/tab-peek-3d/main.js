// PROTOTYPE — throwaway. Hold-to-peek tab overview.
//
// Goal: watch background tab activity without losing track of, or
// switching away from, the current tab. Holding Space tilts the current
// tab's card back (pivoting from its own TOP edge — all content is
// authored with local y=0 at the top, extending downward — so scaling and
// rotating the group happens naturally around that fixed point, no extra
// position math needed) and reveals three small "mini-pane" cards beneath
// it: live, faithfully-scaled copies of the other three tabs. Releasing
// Space snaps back to the normal full-size flat view.
//
// Reuses the WebGL technique proven in ../tab-flip-3d: PerspectiveCamera
// (required for the tilt to show real foreshortening) + MeshStandardMaterial
// + ambient/directional/point lights on Slug geometry, and geometry.addText()
// (the library's own convenience layout method — calls updateBuffers()
// internally, so new/changed lines can't hit the "GPU buffer never flagged
// for re-upload" bug documented in ../slug-glyph-effects/NOTES.md).

import * as THREE from 'three';
import { SlugGenerator, SlugGeometry, injectSlug } from 'three-slug';

// ---------------------------------------------------------------------------
// Tab content. `lines` is the live, mutable buffer (only the tail is ever
// displayed); `feed` is a repeating pool of "next" lines simulating
// background activity — `main` has none, since nothing happens in the tab
// you're actively sitting in for this simulation.
// ---------------------------------------------------------------------------
const TABS = [
  { name: 'main', lines: [
      '$ git status', 'On branch spinner-motion-implementation',
      "Your branch is ahead of 'origin/...' by 29 commits.", '$ ',
    ], feed: [], feedIdx: 0, dirty: false },
  { name: 'tests', lines: [
      '$ swift test --filter Slug', "Test Suite 'SlugTests' started",
    ], feed: [
      '  ok testGlyphCoverage (0.012s)', '  ok testBandPacking (0.031s)',
      '  ok testCurveTrace (0.024s)', '  ok testKindDispatch (0.008s)',
      '47 tests, 47 passed (0.812s)', '$ ',
    ], feedIdx: 0, dirty: false },
  { name: 'build', lines: ['$ ./scripts/build-app'], feed: [
      '[1/212] Compiling LabanCore GlyphEffectTimeline.swift',
      '[89/212] Compiling LabanRenderer VectorGlyphShaders.metal',
      '[150/212] Compiling LabanApp TerminalBitmapView.swift',
      "warning: unused variable 'spill'",
      '[212/212] Build complete! (24.3s)', '$ ',
    ], feedIdx: 0, dirty: false },
  { name: 'logs', lines: ['$ tail -f laban.log'], feed: [
      '[10:41:02] session attach ok (id=3536DD0D)',
      '[10:41:05] glyph-effects: parked (0 live)',
      '[10:41:09] control: GET /debug/state 200 4ms',
      '[10:41:14] session attach ok (id=1192228B)',
      '[10:41:20] display-link: park restored',
      '[10:41:27] control: GET /debug/health 200 1ms',
    ], feedIdx: 0, dirty: false },
];
const MAX_LINES_KEPT = 30; // buffer cap per tab; only the tail is ever shown
const MAX_MAIN_LINES = 8;
const MINI_MAX_LINES = 5;

// ---------------------------------------------------------------------------
// Renderer / scene, sized to the .stage element.
// ---------------------------------------------------------------------------
const stage = document.querySelector('.stage');
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(devicePixelRatio);
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(28, 1, 1, 2000);
camera.position.set(0, 0, 330);
camera.lookAt(0, 0, 0);

scene.add(new THREE.AmbientLight(0xffffff, 0.55));
const keyLight = new THREE.DirectionalLight(0xffffff, 1.1);
keyLight.position.set(-60, 80, 140);
scene.add(keyLight);
const fillLight = new THREE.PointLight(0x6a7bff, 0.35, 800);
fillLight.position.set(80, -40, 100);
scene.add(fillLight);

const CARD_BG = 0x0d1117;
const CARD_BORDER = 0xb393ef;
const TEXT_COLOR = 0xdbe4ff;
// The border reads as pure UI chrome, not terminal content — invisible at
// rest (the resting main card should look like "the terminal," full stop,
// not a bordered card sitting in a scene) and only a faint hint while
// actively tilting/peeking, where it helps read the card's edge as it
// foreshortens. Never full CARD_BORDER intensity.
const BORDER_SUBTLE = 0.3;

// MAIN_HEIGHT/TOP_Y fill nearly the whole camera frustum (half-height ≈82
// at fov=28/D=330) — the resting main card should read as "the terminal,
// full size," not a card floating with unused margin around it. Room for
// the mini row during peek comes entirely from MAIN_PEEK_SCALE (below)
// shrinking the card, not from reserving space at rest.
const MAIN_HEIGHT = 150;
const MINI_HEIGHT = 20;
const MINI_GAP = 6;
const ROW_GAP = 14; // vertical gap between the (shrunk) main card and the mini row
const TOP_Y = 76; // world Y of the main card's top edge (fixed; never animated)
let cardWidth = MAIN_HEIGHT * 1.6; // recomputed on resize to match stage aspect

// ---------------------------------------------------------------------------
// Card building — a small backing+border "panel"; content is authored with
// local y=0 at the TOP edge, extending down to y=-height, so a group's own
// origin IS its top-center pivot. Scaling/rotating the group therefore stays
// anchored at the top with no extra position bookkeeping.
// ---------------------------------------------------------------------------
function buildCard(width, height) {
  const group = new THREE.Group();
  const cy = -height / 2;

  const border = new THREE.Mesh(
    new THREE.PlaneGeometry(width + 3, height + 3),
    new THREE.MeshStandardMaterial({ color: CARD_BORDER, roughness: 0.6, side: THREE.FrontSide, transparent: true }));
  border.position.set(0, cy, -0.4);
  group.add(border);

  const backing = new THREE.Mesh(
    new THREE.PlaneGeometry(width, height),
    new THREE.MeshStandardMaterial({ color: CARD_BG, roughness: 0.85, side: THREE.FrontSide, transparent: true }));
  backing.position.set(0, cy, -0.2);
  group.add(backing);

  group.userData = { border, backing, textMesh: null, width, height, tabIndex: null };
  return group;
}

function resizeCard(group, width, height) {
  group.userData.width = width;
  group.userData.height = height;
  const cy = -height / 2;
  group.userData.border.geometry.dispose();
  group.userData.border.geometry = new THREE.PlaneGeometry(width + 3, height + 3);
  group.userData.border.position.y = cy;
  group.userData.backing.geometry.dispose();
  group.userData.backing.geometry = new THREE.PlaneGeometry(width, height);
  group.userData.backing.position.y = cy;
  if (group.userData.textMesh) group.userData.textMesh.position.x = -width / 2 + group.userData.margin;
}

function setOpacity(group, alpha) {
  group.userData.border.material.opacity = alpha * BORDER_SUBTLE;
  group.userData.backing.material.opacity = alpha;
  if (group.userData.textMesh) group.userData.textMesh.material.opacity = alpha;
  group.visible = alpha > 0.001;
}

const mainGroup = buildCard(cardWidth, MAIN_HEIGHT);
mainGroup.position.set(0, TOP_Y, 0.5);
// Unlike the minis, the main card's backing/text stay opaque always — only
// its border tracks peek progress (set in tick()), starting invisible here.
mainGroup.userData.border.material.opacity = 0;
scene.add(mainGroup);

const miniGroups = [0, 1, 2].map(() => {
  const g = buildCard(cardWidth, MINI_HEIGHT); // width fixed up in resize()
  setOpacity(g, 0);
  scene.add(g);
  return g;
});

// ---------------------------------------------------------------------------
// Font -> Slug data, then populate initial content.
// ---------------------------------------------------------------------------
const generator = new SlugGenerator();
const slugData = await generator.generateFromUrl('./JetBrainsMono-Regular.ttf');

const MAIN_FONT_WORLD = 4.3;
const MINI_FONT_WORLD = 2.0;
const MARGIN_MAIN = 6;
const MARGIN_MINI = 4;

// Mini-panes are ~1/3 the main card's width with no text clipping — a long
// compiler-output line (e.g. "[89/212] Compiling LabanRenderer
// VectorGlyphShaders.metal", 59 chars) is nearly double the character
// budget that actually fits, and simply overflows straight through the
// neighboring mini-pane's space (WebGL doesn't auto-clip geometry to a
// "logical card boundary" — that's DOM/CSS-only behavior). First live test
// showed this as garbled, overlapping text on the build/logs mini-panes.
// Truncating here is realistic anyway — a real thumbnail/preview would too.
const MINI_MAX_CHARS = 30;
function truncateForMini(lines) {
  // Plain ASCII "..." — U+2026 (single-glyph ellipsis) isn't covered by
  // this font either, same tofu-box issue the checkmark hit in
  // ../tab-flip-3d (see that prototype's NOTES.md).
  return lines.map((l) => (l.length > MINI_MAX_CHARS ? l.slice(0, MINI_MAX_CHARS - 3) + '...' : l));
}

function setCardText(group, lines, fontWorld, margin) {
  if (group.userData.textMesh) {
    group.remove(group.userData.textMesh);
    group.userData.textMesh.geometry.dispose();
    group.userData.textMesh.material.dispose();
  }
  const text = lines.join('\n');
  const fontScale = fontWorld / slugData.unitsPerEm;
  const ascentWorld = slugData.ascender * fontScale;
  const geometry = new SlugGeometry(Math.max(1, text.length));
  const material = new THREE.MeshStandardMaterial({
    color: TEXT_COLOR, roughness: 0.5, metalness: 0.0, side: THREE.FrontSide, transparent: true,
  });
  geometry.addText(text, slugData, { fontScale, startX: 0, startY: 0, justify: 'left' });
  const mesh = new THREE.Mesh(geometry, material);
  injectSlug(mesh, material, slugData);
  mesh.position.set(-group.userData.width / 2 + margin, -margin - ascentWorld, 0.2);
  group.add(mesh);
  group.userData.textMesh = mesh;
  group.userData.margin = margin;
}

let currentIndex = 0;
setCardText(mainGroup, TABS[0].lines.slice(-MAX_MAIN_LINES), MAIN_FONT_WORLD, MARGIN_MAIN);
// backing/text materials already default to opacity 1 from construction —
// only the border needed an explicit reset, done at mainGroup's setup above.

// ---------------------------------------------------------------------------
// Sizing — driven by the .stage element's own box.
// ---------------------------------------------------------------------------
// resizeMiniCards() rebuilds GPU geometry (dimensions changed — only needed
// on an actual window resize) separately from layoutMiniRow() (repositions
// only — called every frame during the peek transition, since the mini
// row's Y tracks the main card's live shrink amount; it must NOT dispose/
// recreate PlaneGeometry every frame just to move a Y coordinate).
function resizeMiniCards() {
  const miniWidth = (cardWidth - 2 * MINI_GAP) / 3;
  miniGroups.forEach((g) => resizeCard(g, miniWidth, MINI_HEIGHT));
}
function layoutMiniRow() {
  const miniWidth = (cardWidth - 2 * MINI_GAP) / 3;
  const rowY = TOP_Y - MAIN_HEIGHT * mainPeekScale() - ROW_GAP;
  miniGroups.forEach((g, i) => {
    g.position.set(-cardWidth / 2 + miniWidth / 2 + i * (miniWidth + MINI_GAP), rowY, 0.5);
  });
}
function mainPeekScale() { return peeking || rafHandle ? mainGroup.scale.x : 1; }

function resize() {
  const w = stage.clientWidth, h = stage.clientHeight;
  renderer.setSize(w, h);
  camera.aspect = w / h;
  cardWidth = MAIN_HEIGHT * camera.aspect;
  resizeCard(mainGroup, cardWidth, MAIN_HEIGHT);
  resizeMiniCards();
  layoutMiniRow();
  camera.updateProjectionMatrix();
  render();
}
new ResizeObserver(resize).observe(stage);

function render() { renderer.render(scene, camera); }

// ---------------------------------------------------------------------------
// Peek transition — tilt (rotation.x) + shrink (uniform scale), both
// pivoting naturally around the group's own top-anchored origin. One-shot,
// eased, then parks. Duration and tilt angle are live-tunable (gizmo).
// ---------------------------------------------------------------------------
let TILT_MS = 320;
let tiltDeg = 26;
// Now that MAIN_HEIGHT fills nearly the whole frustum at rest, the mini row
// needs a bigger relative shrink than before (was 0.8 against a 100-unit
// card) to clear a 150-unit card with room to spare — tuned against the
// live layout, not derived from a formula.
const MAIN_PEEK_SCALE = 0.68;
function easeInOutCubic(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }

// `peeking` is the settled state; `peekTarget` is what the (possibly
// in-flight) animation is currently heading toward — they differ exactly
// while transitioning. Deliberately interruptible: a hold-to-peek gesture
// can legitimately reverse mid-animation (a quick tap is a keydown
// immediately followed by keyup), and the first version's hard
// `if (transitioning) return;` guard silently dropped that reversal —
// verified live: dispatching keydown then keyup left `transitioning` stuck
// `true` and rotation pinned at 0 forever, because the release request had
// nowhere to go. Rewritten so a new call always retargets the animation
// from its current live pose instead of being blocked by one in flight.
let peeking = false;
let peekTarget = false;
let animFrom = { scale: 1, tilt: 0, miniOp: 0 };
let animStart = 0;
let rafHandle = 0;

function refreshMinis() {
  const others = TABS.map((_, i) => i).filter((i) => i !== currentIndex);
  others.forEach((tabIndex, slot) => {
    miniGroups[slot].userData.tabIndex = tabIndex;
    setCardText(miniGroups[slot], truncateForMini(TABS[tabIndex].lines.slice(-MINI_MAX_LINES)), MINI_FONT_WORLD, MARGIN_MINI);
  });
}

function setPeek(target) {
  if (peekTarget === target) return; // already heading there (or resting there)
  peekTarget = target;
  if (target) refreshMinis();
  animFrom = {
    scale: mainGroup.scale.x,
    tilt: mainGroup.rotation.x,
    miniOp: miniGroups[0].userData.backing.material.opacity,
  };
  animStart = performance.now();
  if (!rafHandle) rafHandle = requestAnimationFrame(tick);
}

function tick(now) {
  const t = Math.min(1, (now - animStart) / TILT_MS);
  const e = easeInOutCubic(t);
  const endScale = peekTarget ? MAIN_PEEK_SCALE : 1;
  const endTilt = peekTarget ? -(tiltDeg * Math.PI / 180) : 0;
  const endMiniOp = peekTarget ? 1 : 0;
  mainGroup.scale.setScalar(THREE.MathUtils.lerp(animFrom.scale, endScale, e));
  mainGroup.rotation.x = THREE.MathUtils.lerp(animFrom.tilt, endTilt, e);
  const op = THREE.MathUtils.lerp(animFrom.miniOp, endMiniOp, e);
  miniGroups.forEach((g) => setOpacity(g, op));
  // Same 0<->1 peek progress drives the main card's border: invisible at
  // rest, a faint hint while tilting/peeking — never full CARD_BORDER
  // intensity (see BORDER_SUBTLE).
  mainGroup.userData.border.material.opacity = op * BORDER_SUBTLE;
  layoutMiniRow();
  render();
  if (t < 1) {
    rafHandle = requestAnimationFrame(tick);
  } else {
    peeking = peekTarget;
    rafHandle = 0;
    render(); // one settled frame, then park
  }
}

// ---------------------------------------------------------------------------
// Switching the current tab — instant content swap (no card transition of
// its own; the tilt/reveal above is a separate, orthogonal mechanic). If a
// switch happens while peeking, the mini row is refreshed too, since the
// "other three" set changes with it.
// ---------------------------------------------------------------------------
const tabRows = [...document.querySelectorAll('.tab-row')];
function updateSidebar(selectedIndex) {
  tabRows.forEach((r, i) => r.classList.toggle('selected', i === selectedIndex));
}

function switchCurrent(newIndex) {
  if (newIndex === currentIndex) return;
  currentIndex = newIndex;
  setCardText(mainGroup, TABS[currentIndex].lines.slice(-MAX_MAIN_LINES), MAIN_FONT_WORLD, MARGIN_MAIN);
  updateSidebar(currentIndex);
  if (peeking) refreshMinis();
  render();
}

tabRows.forEach((el) => el.addEventListener('click', () => switchCurrent(Number(el.dataset.pane))));

// Clicking a mini-pane "dives in": switch to it and snap back to normal view.
const raycaster = new THREE.Raycaster();
const pointerNdc = new THREE.Vector2();
renderer.domElement.addEventListener('click', (e) => {
  if (!peeking) return;
  const rect = renderer.domElement.getBoundingClientRect();
  pointerNdc.set(((e.clientX - rect.left) / rect.width) * 2 - 1, -((e.clientY - rect.top) / rect.height) * 2 + 1);
  raycaster.setFromCamera(pointerNdc, camera);
  const hit = raycaster.intersectObjects(miniGroups.map((g) => g.userData.backing));
  if (hit.length) {
    const group = hit[0].object.parent;
    const tabIndex = group.userData.tabIndex;
    switchCurrent(tabIndex);
    setPeek(false);
  }
});

updateSidebar(currentIndex);

// ---------------------------------------------------------------------------
// Hold-to-peek input. Guard e.repeat so an OS key-repeat while held doesn't
// restart the transition on every repeat event.
// ---------------------------------------------------------------------------
window.addEventListener('keydown', (e) => {
  if (e.code === 'Space' && !e.repeat) { setPeek(true); e.preventDefault(); }
});
window.addEventListener('keyup', (e) => {
  if (e.code === 'Space') { setPeek(false); e.preventDefault(); }
});

// ---------------------------------------------------------------------------
// Background activity simulation — the other tabs keep "running" whether
// you're peeking or not; peeking just reveals whatever's already there and
// keeps live-refreshing while held.
// ---------------------------------------------------------------------------
setInterval(() => {
  let anyDirty = false;
  for (const tab of TABS) {
    if (!tab.feed.length || Math.random() >= 0.5) continue;
    tab.lines.push(tab.feed[tab.feedIdx % tab.feed.length]);
    tab.feedIdx++;
    if (tab.lines.length > MAX_LINES_KEPT) tab.lines.shift();
    tab.dirty = true;
    anyDirty = true;
  }
  if (!anyDirty) return;

  if (TABS[currentIndex].dirty) {
    setCardText(mainGroup, TABS[currentIndex].lines.slice(-MAX_MAIN_LINES), MAIN_FONT_WORLD, MARGIN_MAIN);
  }
  if (peeking && !rafHandle) {
    for (const g of miniGroups) {
      const idx = g.userData.tabIndex;
      if (idx != null && TABS[idx].dirty) {
        setCardText(g, truncateForMini(TABS[idx].lines.slice(-MINI_MAX_LINES)), MINI_FONT_WORLD, MARGIN_MINI);
      }
    }
  }
  render();
  for (const tab of TABS) tab.dirty = false;
}, 1800);

// ---------------------------------------------------------------------------
// Tuning gizmo — tilt angle + transition duration.
// ---------------------------------------------------------------------------
const tiltSlider = document.getElementById('tilt-slider');
const tiltLabel = document.getElementById('tilt-label');
tiltSlider.addEventListener('input', () => {
  tiltDeg = Number(tiltSlider.value);
  tiltLabel.textContent = `${tiltDeg}°`;
});

const durationSlider = document.getElementById('duration-slider');
const durationLabel = document.getElementById('duration-label');
durationSlider.addEventListener('input', () => {
  TILT_MS = Number(durationSlider.value);
  durationLabel.textContent = `${TILT_MS}ms`;
});

resize();
document.getElementById('loading')?.remove();
