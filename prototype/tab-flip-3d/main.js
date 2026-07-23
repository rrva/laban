// PROTOTYPE — throwaway. 3D card-flip tab transition.
//
// Technique, ported from github.com/manthrax/JSlug demo/main.js:
//   - THREE.PerspectiveCamera (that demo used one to let OrbitControls fly
//     around; here it's fixed, but perspective is still required — an
//     orthographic camera shows no foreshortening, so a Y-axis rotation
//     would look like a flat rectangle scaling in X, not a card turning).
//   - Slug geometry rendered with THREE.MeshStandardMaterial (not the flat
//     MeshBasicMaterial the other two prototypes in this repo use) so real
//     ambient + directional lighting gives the rotating card visible
//     dimensional shading — that lighting response is most of what makes
//     the JSlug demo read as "real" 3D rather than a flat image on a hinge.
//   - geometry.addText(...), three-slug's own convenience layout method
//     (used by the JSlug demo itself) — NOT the manual per-glyph
//     geometry.addGlyph() loop from the slug-glyph-effects prototype next
//     door. addText() calls updateBuffers() internally, so the "new glyphs
//     invisible because the GPU buffer was never flagged for re-upload" bug
//     documented in ../slug-glyph-effects/NOTES.md can't happen here by
//     construction — this prototype takes the higher-level, safer path
//     since per-glyph ANSI coloring isn't the thing being tested.
//
// The flip itself is a standard two-sided-card trick, not anything
// three-slug-specific: a "hinge" Group holds two child Groups (front/back),
// each containing an opaque backing plane + border plane + Slug text mesh,
// all with `side: THREE.FrontSide` so only whichever face currently points
// toward the camera renders. `back` is pre-rotated 180° around Y so that
// when `hinge.rotation.y` animates 0 -> PI, front sweeps away (culled past
// 90°) exactly as back sweeps into view, arriving right-side-up (not
// mirrored) because the two 180° rotations compose to identity.

import * as THREE from 'three';
import { SlugGenerator, SlugGeometry, injectSlug } from 'three-slug';

// ---------------------------------------------------------------------------
// Tab content — plain text (no per-glyph color channel in this prototype;
// see NOTES.md "Scoping: no per-glyph color here").
// ---------------------------------------------------------------------------
const TABS = [
  {
    name: 'main',
    text: `$ git status
On branch spinner-motion-implementation
Your branch is ahead of 'origin/...' by 29 commits.
$ `,
  },
  {
    name: 'tests',
    text: `$ swift test --filter Slug
Test Suite 'SlugTests' started
  ok testGlyphCoverage (0.012s)
  ok testBandPacking (0.031s)
47 tests, 47 passed (0.812s)
$ `,
  },
  {
    name: 'build',
    text: `$ ./scripts/build-app
[1/212] Compiling LabanCore GlyphEffectTimeline.swift
[89/212] Compiling LabanRenderer VectorGlyphShaders.metal
warning: unused variable 'spill'
[212/212] Build complete! (24.3s)
$ `,
  },
];

// ---------------------------------------------------------------------------
// Renderer / scene, sized to the .stage element (not the whole window — the
// sidebar takes up its own width).
// ---------------------------------------------------------------------------
const stage = document.querySelector('.stage');
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(devicePixelRatio);
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(28, 1, 1, 2000);
camera.position.set(0, 0, 236);
camera.lookAt(0, 0, 0);

scene.add(new THREE.AmbientLight(0xffffff, 0.55));
const keyLight = new THREE.DirectionalLight(0xffffff, 1.1);
keyLight.position.set(-60, 80, 140);
scene.add(keyLight);
const fillLight = new THREE.PointLight(0x6a7bff, 0.35, 800);
fillLight.position.set(80, -40, 100);
scene.add(fillLight);

// Card size in world units; width follows the stage's current aspect ratio.
const CARD_HEIGHT = 100;
let cardWidth = CARD_HEIGHT * 1.6;

const hinge = new THREE.Group();
scene.add(hinge);

const CARD_BG = 0x0d1117;
const CARD_BORDER = 0xb393ef;
const TEXT_COLOR = 0xdbe4ff;

function buildFace(zSign) {
  const face = new THREE.Group();
  face.position.z = zSign * 0.4; // tiny separation only, to avoid z-fighting at the edge-on moment

  const border = new THREE.Mesh(
    new THREE.PlaneGeometry(cardWidth + 3, CARD_HEIGHT + 3),
    new THREE.MeshStandardMaterial({ color: CARD_BORDER, roughness: 0.6, side: THREE.FrontSide }));
  border.position.z = -0.4;
  face.add(border);

  const backing = new THREE.Mesh(
    new THREE.PlaneGeometry(cardWidth, CARD_HEIGHT),
    new THREE.MeshStandardMaterial({ color: CARD_BG, roughness: 0.85, side: THREE.FrontSide }));
  backing.position.z = -0.2;
  face.add(backing);

  face.userData.border = border;
  face.userData.backing = backing;
  face.userData.textMesh = null; // populated once font/geometry are ready
  return face;
}

const frontFace = buildFace(+1);
const backFace = buildFace(-1);
// backFace's pre-rotation is set fresh per-flip in flipTo() (axis is
// user-tunable), not here — it stays at identity until the first flip;
// harmless since it isn't visible at rest either way.
hinge.add(frontFace, backFace);

// ---------------------------------------------------------------------------
// Font -> Slug data, then populate both faces with their initial tabs.
// ---------------------------------------------------------------------------
const generator = new SlugGenerator();
const slugData = await generator.generateFromUrl('./JetBrainsMono-Regular.ttf');

const FONT_WORLD = 4.3;
const fontScale = FONT_WORLD / slugData.unitsPerEm;
const ascentWorld = slugData.ascender * fontScale;
const MARGIN = 8;

function textMeshFor(text) {
  const geometry = new SlugGeometry(Math.max(1, text.length));
  const material = new THREE.MeshStandardMaterial({
    color: TEXT_COLOR, roughness: 0.5, metalness: 0.0, side: THREE.FrontSide,
  });
  geometry.addText(text, slugData, { fontScale, startX: 0, startY: 0, justify: 'left' });
  const mesh = new THREE.Mesh(geometry, material);
  injectSlug(mesh, material, slugData);
  return mesh;
}

function setFaceContent(face, tabIndex) {
  if (face.userData.textMesh) {
    face.remove(face.userData.textMesh);
    face.userData.textMesh.geometry.dispose();
    face.userData.textMesh.material.dispose();
  }
  const mesh = textMeshFor(TABS[tabIndex].text);
  mesh.position.set(-cardWidth / 2 + MARGIN, CARD_HEIGHT / 2 - MARGIN - ascentWorld, 0.2);
  face.add(mesh);
  face.userData.textMesh = mesh;
  face.userData.tabIndex = tabIndex;
}

setFaceContent(frontFace, 0);
setFaceContent(backFace, 1); // pre-warm; overwritten before it's ever actually shown

// ---------------------------------------------------------------------------
// Sizing — driven by the .stage element's own box, not window size.
// ---------------------------------------------------------------------------
function resize() {
  const w = stage.clientWidth, h = stage.clientHeight;
  // updateStyle must stay true (the default) here: with setPixelRatio(dpr)
  // the drawing buffer is dpr*w x dpr*h, and only passing updateStyle=true
  // makes Three.js also set canvas.style.width/height to the CSS w/h — skip
  // it and the canvas has no CSS size override, so it falls back to its
  // width/height *attributes* (the dpr-scaled buffer size) as CSS pixels,
  // rendering at ~dpr times the intended size.
  renderer.setSize(w, h);
  camera.aspect = w / h;
  cardWidth = CARD_HEIGHT * camera.aspect;
  for (const face of [frontFace, backFace]) {
    face.userData.border.geometry.dispose();
    face.userData.border.geometry = new THREE.PlaneGeometry(cardWidth + 3, CARD_HEIGHT + 3);
    face.userData.backing.geometry.dispose();
    face.userData.backing.geometry = new THREE.PlaneGeometry(cardWidth, CARD_HEIGHT);
    if (face.userData.textMesh) face.userData.textMesh.position.x = -cardWidth / 2 + MARGIN;
  }
  camera.updateProjectionMatrix();
  render();
}
new ResizeObserver(resize).observe(stage);

function render() { renderer.render(scene, camera); }

// ---------------------------------------------------------------------------
// The flip — a one-shot 0 -> PI rotation, eased, then a hard park. No
// continuous animation once settled, same principle as the other two
// prototypes in this repo. Duration and axis are live-tunable (gizmo below);
// both are read fresh at the START of each flip, so changing either between
// flips is safe — an in-flight flip always finishes with whatever it
// started with.
// ---------------------------------------------------------------------------
let FLIP_MS = 1400;
let flipAxis = 'y'; // 'y' = horizontal (page-turn); 'x' = vertical (flip-clock)
function easeInOutCubic(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }

const tabRows = [...document.querySelectorAll('.tab-row')];
function updateSidebar(selectedIndex) {
  tabRows.forEach((r, i) => r.classList.toggle('selected', i === selectedIndex));
}

let frontIndex = 0;
let flying = false;

function flipTo(index) {
  if (flying || index === frontIndex) return;
  flying = true;
  // Sidebar reflects the navigation target immediately — it must NOT wait
  // for frontIndex, which only updates once the flip finishes. (First pass
  // of this prototype called updateSidebar() using the stale frontIndex
  // right after starting the flip, so the sidebar silently lagged the
  // visible card for the entire animation.)
  updateSidebar(index);
  setFaceContent(backFace, index);

  // The "two 180deg rotations compose to identity, so the incoming face
  // arrives right-side-up" trick only holds if the pre-rotation and the
  // animated rotation are around the SAME axis. Axis is user-tunable
  // mid-session, so both get set fresh here rather than once at startup.
  const axis = flipAxis;
  hinge.rotation.set(0, 0, 0);
  backFace.rotation.set(0, 0, 0);
  backFace.rotation[axis] = Math.PI;

  const duration = FLIP_MS;
  const start = performance.now();
  function tick(now) {
    const t = Math.min(1, (now - start) / duration);
    hinge.rotation[axis] = easeInOutCubic(t) * Math.PI;
    render();
    if (t < 1) {
      requestAnimationFrame(tick);
    } else {
      hinge.rotation[axis] = 0;
      setFaceContent(frontFace, index);
      frontIndex = index;
      flying = false;
      render(); // one settled frame, then park
    }
  }
  requestAnimationFrame(tick);
}

tabRows.forEach((el) => el.addEventListener('click', () => flipTo(Number(el.dataset.pane))));
window.addEventListener('keydown', (e) => {
  const n = Number(e.key);
  if (n >= 1 && n <= TABS.length) flipTo(n - 1);
});

// ---------------------------------------------------------------------------
// Tuning gizmo — duration slider + horizontal/vertical axis toggle.
// ---------------------------------------------------------------------------
const durationSlider = document.getElementById('duration-slider');
const durationLabel = document.getElementById('duration-label');
durationSlider.addEventListener('input', () => {
  FLIP_MS = Number(durationSlider.value);
  durationLabel.textContent = `${(FLIP_MS / 1000).toFixed(2)}s`;
});

const axisButtons = { y: document.getElementById('axis-h'), x: document.getElementById('axis-v') };
function setAxis(axis) {
  flipAxis = axis;
  for (const [key, btn] of Object.entries(axisButtons)) btn.classList.toggle('active', key === axis);
}
axisButtons.y.addEventListener('click', () => setAxis('y'));
axisButtons.x.addEventListener('click', () => setAxis('x'));
setAxis('y');

resize();
updateSidebar(frontIndex);
document.getElementById('loading')?.remove();
