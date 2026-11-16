# Voxel RTS (working title)

A Command & Conquer 1 / Red Alert 2-style RTS with light incremental elements, in
**Godot 4.7.1** (GDScript), by Mark Silvester / Pickle Plum Studios. Built on the pixel
view from Two Billion Presents. Everything on the battlefield is voxel: tanks and
buildings take visible damage where they're hit and crumble to dust when destroyed.
RTS 8/10, incremental 2/10: clicking buildings and units speeds them up.

The design lives in the GDD (a Claude Doc): "Voxel RTS Incremental — GDD",
https://claude.ai/artifact/XBsbeS5MuWrBLZzDXPEo2B. Check it before design work.

The Godot project is the repo root.

## How we work

- **Pull before anything** (`git pull --rebase origin main`). Mark makes art and scenes
  in parallel and pushes often.
- Make the change in the repo, test it headless, then commit and push to `main` while
  Mark playtests. Small, focused commits with a message that says what changed and why.
- Don't overwrite Mark's art or scenes wholesale; edit only the nodes a change needs.
- If Mark says "no need to do anything, just so you're aware", don't act.
- Mark understands the code and likes to know *why*: explain design choices briefly,
  flag trade-offs, and say when something was left out or is a guess.
- Work in small, testable steps. No over-engineering.

## GDScript style

- **Explicit types everywhere**, never `:=`: `var speed: float = 1.3`,
  `for unit: Unit in units:`, `func get_cost() -> int:`.
- Doc comments (`##`) on classes and exported settings, written plainly, saying what
  it's for and any gotcha. Comments explain why, not what.
- Architecture: **services** (autoloads in `Scripts/Services/`), **components**
  (`Scripts/Components/`, one job each, found by type), **bases** (`Scripts/Bases/`).
  World mouse input goes through `InteractionService`, not scattered `_input`s (the
  camera rig is the exception, carried over from Two Billion Presents; the voxel test
  gun is another, on Ctrl + click).
- **Data lives in resources** (`.tres`) so Mark can tune in the Inspector. Prefer adding
  a field to a resource over a hard-coded number.
- Player-facing text: short, British English, straight quotes.

## Pixel view (rendering)

- `game.tscn` (main scene) → `PixelView` renders `Scenes/World.tscn` into a low-res
  `SubViewport` and upscales it with nearest filtering. HUD goes outside it, at full res.
- `PixelView.pixel_scale` = base-viewport pixels per world pixel. The project uses
  `canvas_items` stretch with the default 1152x648 base, so 4 = 288x162 world pixels,
  stretched to the window (not a whole number at 1080p). 2 = 576x324.
- Decided 2026-11-16: the game uses the pixel view at quarter res with 1/16 voxels
  (16 ppu). The test scene can still show half res with 1/32 voxels (F2) and full
  resolution with no pixel view (F3), for comparison only.
- `PixelSnapCamera` snaps to the low-res grid and hands the leftover sub-pixel to the
  display, so panning is smooth without crawling pixels. `CameraRig` pans/zooms in
  pixel-perfect steps (`zoom_levels` = low-res pixels per world unit).
- Moving objects get a `PixelSnapComponent` so they step a clean pixel at a time.
- **`ViewService`** (autoload): the world camera, mouse position in world-view pixels,
  and world-to-screen. Raycasts must use `ViewService.get_camera()` and
  `ViewService.get_mouse_position()`, not the root viewport's.
- The look is `Scripts/Shaders/pixel_toon.gdshaderinc` (banded lighting; band count and
  ramp are project Shader Globals). Three thin shaders include it: `pixel_toon.gdshader`
  (ordinary models), `voxel_toon.gdshader` (voxel bodies) and `voxel_debris.gdshader`.
  Change the look in the include, not in a variant. Outlines are a full-screen pass on
  the camera (`outline_shader.tres`).
- Basic team/ground materials are in `Materials/`.

## Voxels

Rules (from the GDD):

- HP drives gameplay; voxels are visual only. Nothing about them needs syncing.
- Art is authored in MagicaVoxel (`.vox`, read at runtime by `VoxReader`; barrel/front
  points +Y there). Export presets must include `*.vox` under "Filters to export
  non-resource files" until there's an import plugin.
- Team colour: magenta palette entries (FF00FF, CC00CC, 990099, 660066) are swapped for
  `VoxelBody.team_color` in the shader, so one model serves every team. The shared
  palette is `Art/Voxel/palette.png`.
- No browser build for this project (decided 2026-11-16), so threads and Forward+-only
  features are fine.

How it works (`Scripts/Voxel/`, `Scripts/Services/voxel_service.gd`):

- `VoxelGrid`: `cells` (palette index), `shade` (scorch), `occ` (one bit per voxel, 16
  per word). **Grid arrays are never written in place once in use** (packed arrays are
  shared by reference, and worker threads read them); an edit makes new arrays and the
  body swaps them in.
- `VoxelMesher`: exterior faces only, one 16x16x16 section at a time, found with bit
  masks on `occ`. Meshes are in voxel units; the body scales them.
- `VoxelModel` (one per file, cached by `VoxelService`): the grid, one whole mesh, and
  the same thing as section meshes. Built once at load, across the worker threads.
- `VoxelBody`: draws the model's whole mesh until first hit, then sections. `carve()`
  only queues the hit.
- `VoxelEditJob`: runs on `WorkerThreadPool`. Copies the arrays, carves, finds anything
  cut loose (search out from the crater, down first), meshes the sections that changed.
  One job per body at a time. `VoxelService` hands results back on the main thread
  under a small per-frame budget; the body swaps arrays and meshes, throws the debris
  and spawns any falling chunk. Sections wholly inside a chunk keep their meshes.
- Crumbling is the shader hiding everything above a falling height (`clip_height`, an
  instance uniform). No meshing.
- `VoxelDebris`: one MultiMesh; a piece's start, velocity and timing are packed into
  its instance transform and the vertex shader works out the flight. No per-frame CPU.
- Worker code must not touch nodes or the scene tree. Creating `ArrayMesh`es on workers
  is fine with a real renderer; with `--headless` no meshes are made at all.
- `Scripts/Tools/voxel_test_gun.gd` is the test harness (click to shoot, F2 detail,
  on-screen main-thread cost). Test models come from `Tools/make_test_vox.py`.

Not done yet: greedy meshing, an import plugin for `.vox`, debris bouncing on anything
but the ground plane, a native (C#/C++) mesher if GDScript ever isn't enough.

## Units

- `Unit` (`Scripts/Bases/unit.gd`): the hub for anything selectable. Its look is a
  `VoxelBody` child, its movement a `MoveComponent` child, its numbers a `UnitData`
  resource (`Units/*.tres`). Scene: `Units/tank.tscn` (Claude's test tank for now).
- `MoveComponent`: straight line to a point; if it's facing more than
  `turn_in_place_degrees` off, it stops and pivots first. No pathfinding, avoidance or
  slopes yet.
- `AttackComponent`: closes to within range, turns the whole unit to face the target
  (no separate turret yet), fires a `Shell` (`Scripts/World/shell.gd`) per reload until
  cancelled. Shells fly straight and carve the first voxel body in their path that
  isn't the shooter, friend or foe. Visual only: no hit points yet.
- `SelectionService` holds hovered/selected (one unit for now); `InteractionService`
  turns the mouse into orders. Controls (decided 2026-11-16): left click selects, left
  click on nothing deselects, right click moves, A + right click attacks (a unit or a
  spot). A is the `attack_modifier` action; the camera pans on the arrow keys.
  Picking is voxel-exact via `VoxelBody.raycast`.
- Hover (yellow) and selection (green) lines are drawn by the camera's outline pass.
  A body marks itself through ROUGHNESS (`outline_mark` instance uniform in the voxel
  shader; values must match `outline.gdshader`). Needs Forward+, and no MSAA on the
  world viewport (it blends the marks).
- Mark's idea for later, not built: tanks take more damage from behind.
- Sizes come from the characters: everything else is scaled to whatever soldier
  height Mark picks. `Scenes/size_lineup.tscn` (in the test world) shows placeholder
  riflemen, bazooka soldiers and dogs at 12/16/20/24 voxels, from
  `Tools/make_test_characters.py`. Remove it once the size is chosen.

## Testing (headless)

Godot 4.7.1 Linux build at `/tmp/godot/Godot_v4.7.1-stable_linux.x86_64` (download it from
the GitHub release if missing). From the repo root:

```
# after adding a class_name or new assets
/tmp/godot/Godot_v4.7.1-stable_linux.x86_64 --headless --import
# run a test script (extends SceneTree) with rendering, for screenshots
xvfb-run -a -s "-screen 0 1920x1080x24" /tmp/godot/Godot_v4.7.1-stable_linux.x86_64 \
  --rendering-driver opengl3 --resolution 1920x1080 --script res://zz_t.gd
```

- Test scripts are named `zz_*.gd` and **deleted before committing**.
- They mustn't name autoload-dependent classes at compile time: use
  `root.get_node("ViewService")`, `call()`, `get()`, `load()`.
- A script error leaves Godot hanging without quitting; run with a `timeout`, and add
  `--verbose` to find the error.
- For screenshots that match Mark's PC, render Forward+ on software Vulkan: install
  `mesa-vulkan-drivers` (lavapipe), then use `--rendering-driver vulkan
  --rendering-method forward_plus` instead of `--rendering-driver opengl3`. It's slower
  per frame. opengl3 gives the Compatibility (browser) look, brighter and more saturated.
- Look at screenshots before saying visual work is done.
- To drive the mouse in a test: `DisplayServer.warp_mouse()` (window pixels) to move,
  `Input.parse_input_event()` for clicks. `push_input` doesn't move the mouse position
  the services read.
- `--headless` has no renderer, so voxel bodies have no meshes there: fine for timing
  the main thread, useless for checking meshes. For those, run on lavapipe and compare
  each drawn section with a fresh `VoxelMesher.build_section` of the body's grid.
