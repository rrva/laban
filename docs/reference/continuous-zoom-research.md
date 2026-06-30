# Deep research: continuous terminal zoom & zoom-out UX (2026-06-30)
## Summary

No GPU-accelerated terminal emulator does continuous/fractional smooth canvas zoom: Kitty, Ghostty, WezTerm, iTerm2/Terminal.app, and Alacritty all treat a font-size change as a discrete re-rasterize plus an immediate grid reflow inside a fixed-pixel window, because a terminal is structurally a fixed character-cell grid and cannot reflow into a free-form scalable canvas the way a browser or PDF can (the running program is not told to produce more content until a SIGWINCH). The "continuous transient, then reflow on release" pattern the question describes is real and proven, but only in domains that own or can re-render their content: Google Maps scales vector polygons smoothly during a pinch and swaps in fresh tiles only when the user pauses, and RealVNC's Dynamic Resolution live-reflows a server-owned virtual desktop to the new window size (the remote-desktop analog of SIGWINCH), clamped to a maximum framebuffer. The canonical answer to the zoom-OUT "no content for the revealed area" problem comes from tile renderers: never show transparent/empty gaps — cover the revealed region with an opaque fallback (Google Maps starts the lower-zoom underlay fully opaque) or upscale the existing highest-resolution raster to fill (Leaflet overscaling). Signed-distance-field glyph rendering makes a transient vertex-projection scale visually safe, since SDF edges stay ~1px sharp under arbitrary scale-down/up. Recommendation for the macOS Metal terminal: a hybrid — scale the SDF glyph canvas during the gesture, fill the zoom-out margin with the opaque terminal background (do not fake content, do not live-SIGWINCH every frame), then commit one real font-size + SIGWINCH reflow on gesture release to snap real rows/cols into the margin, with a soft clamp/rubber-band at the edges; a hard clamp at 1.0 is rejected because it defeats zoom-out entirely.
## Findings

### All major terminal emulators implement font-size zoom as discrete stepping with an immediate grid reflow inside a fixed-pixel window, not as a continuous/fractional canvas scale. Ghostty is the best-d
- confidence: high  vote: 3-0 (merged from claims 12,13,14,15,16; supported by 11)
- evidence: Ghostty Collaborator rhodes-b: a font-size change 'reflows text just like changing the text size would', and the speed of that reflow is what makes lines visibly disappear (xterm is immune 'because it never reflows'). Maintainer mitchellh: 'By default, changing the font size causes a grid reflow, not a window resize' and 'The decision to make it intentional was mine... My previous terminal was Kitty and it behaved this way... Other terminals also behave this way (Alacritty another).' Independent source-code analysis confirms the window keeps its pixel size while setCellSize queues a resize/SIG
  - https://github.com/ghostty-org/ghostty/discussions/7605
  - https://github.com/ghostty-org/ghostty/discussions/2661
  - https://github.com/ghostty-org/ghostty/discussions/13106

### Even where the font-size VALUE type is continuous/fractional, zoom is still applied as discrete re-rasterize-plus-reflow steps, not a per-frame continuous transform. WezTerm's font_size accepts fracti
- confidence: high  vote: 3-0 (merged from claims 19,11)
- evidence: Official WezTerm docs: font_size is a float, default 12.0, and 'You may use fractional point sizes, such as 13.3, to fine tune the size.' Ghostty discussion #13106: the magnify(with:) override 'hooks right into the existing increase_font_size and decrease_font_size actions', modeled on scrollWheel logic; those actions re-rasterize the glyph atlas at a new point size and reflow the grid per step. The author asked for 'a fluid, seamless, Safari-style pinch gesture to scale text dynamically', confirming the goal of continuous scale and the gap between it and the discrete-step implementation. Frac
  - https://wezterm.org/config/lua/config/font_size.html
  - https://github.com/ghostty-org/ghostty/discussions/13106

### The terminal's fixed character-grid model is the root constraint, and it is preserved even by the most ambitious in-band text-scaling design. Kitty's text-sizing protocol scales rendered font size wit
- confidence: high  vote: 3-0 (merged from claims 4,5; supported by 3 at 2-1)
- evidence: Kitty docs (Kovid Goyal, primary): 'the fractional scale does not affect the number of cells the text occupies, instead, it just adjusts the rendered font size within those cells'; the main scale 's' is an integer 1-7 ('Using the main scale parameter (s) gives us only 7 font sizes'); and 'This protocol does not change the character grid based nature of the terminal.' The protocol is 'intentionally limited in flexibility precisely because it still has to work with the character cell grid based fundamental nature of the terminal.' Caveat: this protocol is for application-requested in-content siz
  - https://sw.kovidgoyal.net/kitty/text-sizing-protocol/

### Bridging a continuous pinch gesture onto a discrete-zoom terminal is exactly what continuous-gesture helpers already do, and they scale no canvas. PinchBar intercepts trackpad input via a background e
- confidence: high  vote: 3-0 (merged from claims 0,1,17,18)
- evidence: PinchBar README (primary repo): the Font Size preset 'maps pinch gestures to CMD+ and CMD-... I use this preset for text editors like Xcode and Terminal' and 'accumulates the magnification over your continuous pinch gesture and sends keyboard events according to exceeded intervals.' Mechanism: 'a special background thread to intercept and modify user input before it is being processed by the targeted app'; it 'replaces all pinch events with scroll events and adds a modifier flag for the CMD key.' Continuous zoom is the target app's capability: 'Cubase has build-in support for continuous zoom o
  - https://github.com/pnoqable/PinchBar

### The state-of-the-art continuous-zoom pattern in apps that don't fully own their content is 'scale-as-transient, reflow-on-pause': scale existing geometry smoothly during the gesture but produce NO fre
- confidence: high  vote: 3-0 (claim 6)
- evidence: Google Design / Medium (Antin Harasymiv, the prototype's own author): 'As soon as the user pauses zooming, the map quickly loads the vector tiles at the new zoom level and swaps them out', and 'while it's very smoothly scaling the tiles, there is no new information until you stop.' The client keeps labels positioned and 'scale[s] all the polygons' during the gesture without fetching detail. Note MapBox chooses to 'more aggressively load new tiles during the zoom transitions', showing wait-until-pause is a design choice, not a hard requirement — relevant to the live-throttled-reflow alternative
  - https://medium.com/google-design/google-maps-cb0326d165f5

### The canonical answer to the zoom-OUT 'no content for the revealed area' problem is: never expose transparent/empty gaps — cover the revealed region with an OPAQUE fallback or upscale existing content 
- confidence: high  vote: 3-0 / 2-1 (merged from claims 7,8)
- evidence: Google Design/Medium (prototype author): 'if we were zooming out, from 1 to 0... we cannot animate the opacity on the grey tile because it would leave some gaps'; 'it's better to start it fully opaque — otherwise there will be patchy gaps.' Leaflet (creator Vladimir Agafonkin's maxNativeZoom/'overscaling', PR #1802): 'Leaflet will upscale (stretch) tiles from the highest native zoom level to fill the viewport.' Caveat: Leaflet overscaling triggers on zoom-IN past max native zoom (magnify-to-fill), not the zoom-OUT gap; the cover-don't-gap principle transfers, but the direction differs, so the 
  - https://medium.com/google-design/google-maps-cb0326d165f5
  - https://www.w3tutorials.net/blog/leaflet-zoom-in-further-and-stretch-tiles/

### Remote desktop's RealVNC 'Dynamic Resolution' is the closest cross-domain analog to a terminal SIGWINCH: instead of scaling a fixed rasterized canvas and letterboxing, it live-reflows REAL content by 
- confidence: high  vote: 3-0 (merged from claims 2,21,22)
- evidence: RealVNC Help Center (primary, Viewer/Server 7.6.0+): 'dynamically change resolution of the virtual desktop to match the size of the connected RealVNC Viewer window' — a true server-side framebuffer/RandR change emitting ConfigureNotify/RRScreenChange so apps re-layout (the SIGWINCH analog). Enable by 'clicking the 1:1 resolution button on the toolbar... then resize the RealVNC Viewer window'; gated to Virtual Mode with AllowDynamicResolution=TRUE. Bound: 'Xvnc will set the maximum framebuffer for a session to match either the largest resolution in the RandR parameter... or 1024x768 if RandR is
  - https://help.realvnc.com/hc/en-us/articles/12760979479069-What-is-Dynamic-Resolution-for-Virtual-Mode

### Signed-distance-field (SDF) glyph rendering makes a transient vertex-projection scale visually viable: SDF edges stay ~1px-wide and antialiased regardless of how far text is scaled up or down (the fra
- confidence: high  vote: 3-0 / 2-1 (merged from claims 9,10)
- evidence: Metal By Example (Warren Moore): 'This produces an edge band that is roughly one pixel wide, regardless of how much the text is scaled up or down', with the published shader line edgeWidth = 0.7 * length(float2(dfdx(dist), dfdy(dist))) (screen-space gradient into smoothstep); and 'the edges of the glyphs remain quite sharp even under extreme magnification... in contrast to the way a pre-rasterized bitmap texture would become jagged or blurry.' Corroborated by Valve's 2007 SIGGRAPH SDF paper, Chlumsky MSDF, Red Blob Games. Caveat: single-channel SDF rounds sharp CORNERS at extreme magnification
  - https://metalbyexample.com/rendering-text-in-metal-with-signed-distance-fields/

### WCAG's reflow criterion defines precisely the reflowable behavior a terminal grid structurally lacks: as content is enlarged, words re-wrap so lines never exceed the viewport, letting the user scroll 
- confidence: high  vote: 3-0 (claim 20)
- evidence: W3C Understanding SC 1.4.10 (primary): 'As text is resized, the words wrap so that the text lines do not exceed the viewport'; normative requirement is content usable 'without requiring scrolling in two dimensions.' The terminal half is the synthesis author's analogy but technically accurate: terminal content is produced against the current grid size and only updated when the program is resized. Minor gloss imprecisions (the single permitted scroll axis is block-progression, and reflow is the means not the literally-required outcome) do not affect the core contrast with the non-reflowable term
  - https://www.w3.org/WAI/WCAG22/Understanding/reflow.html

### RECOMMENDATION (synthesized): for a macOS Metal terminal that scales its glyph canvas in the vertex projection during the gesture and commits a real font-size + SIGWINCH reflow on release, the best zo
- confidence: medium  vote: synthesis across confirmed claims 2,6,7,8,9,10,13,20,21,22
- evidence: This recommendation is an analogy-based synthesis: no terminal currently does continuous zoom, so it is assembled from cross-domain primary evidence — Google Maps scale-as-transient/reflow-on-pause (claim 6), opaque-cover on zoom-out reveal (claim 7) and Leaflet fill-don't-blank (claim 8), SDF scale-sharpness making the transient viable (claims 9-10), VNC live-reflow being gated/bounded and clamped (claims 2,21,22), Ghostty's fast-reflow-causes-disappearing-text warning against per-frame reflow (claim 13), and the WCAG/terminal constraint that content for the margin does not exist until SIGWIN
  - https://medium.com/google-design/google-maps-cb0326d165f5
  - https://www.w3tutorials.net/blog/leaflet-zoom-in-further-and-stretch-tiles/
  - https://metalbyexample.com/rendering-text-in-metal-with-signed-distance-fields/
  - https://help.realvnc.com/hc/en-us/articles/12760979479069-What-is-Dynamic-Resolution-for-Virtual-Mode
  - https://github.com/ghostty-org/ghostty/discussions/7605
  - https://www.w3.org/WAI/WCAG22/Understanding/reflow.html
