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
  Input goes through a dedicated input service, not scattered `_input`s (the camera rig
  is the current exception, carried over from Two Billion Presents).
- **Data lives in resources** (`.tres`) so Mark can tune in the Inspector. Prefer adding
  a field to a resource over a hard-coded number.
- Player-facing text: short, British English, straight quotes.

## Pixel view (rendering)

- `game.tscn` (main scene) → `PixelView` renders `Scenes/World.tscn` into a low-res
  `SubViewport` and upscales it with nearest filtering. HUD goes outside it, at full res.
- `PixelView.pixel_scale` = screen pixels per world pixel (4 at 1080p = 480x270). The
  GDD wants to test 2x/3x/4x for voxel detail.
- `PixelSnapCamera` snaps to the low-res grid and hands the leftover sub-pixel to the
  display, so panning is smooth without crawling pixels. `CameraRig` pans/zooms in
  pixel-perfect steps (`zoom_levels` = low-res pixels per world unit).
- Moving objects get a `PixelSnapComponent` so they step a clean pixel at a time.
- **`ViewService`** (autoload): the world camera, mouse position in world-view pixels,
  and world-to-screen. Raycasts must use `ViewService.get_camera()` and
  `ViewService.get_mouse_position()`, not the root viewport's.
- All 3D materials use `Scripts/Shaders/pixel_toon.gdshader` (banded lighting; band count
  and ramp are project Shader Globals). Outlines are a full-screen pass on the camera
  (`outline_shader.tres`); creases need Forward+, the browser build gets outlines only.
- Basic team/ground materials are in `Materials/`.

## Voxel plan (from the GDD)

- HP drives gameplay; voxels are visual only.
- Build only exterior faces; one mesh per object (or per part: hull, turret).
- Undamaged units of a type share a mesh; a unit gets its own voxel grid when first hit.
- Remeshes are queued with a per-frame budget on `WorkerThreadPool`; debris is pooled
  and capped.
- Art is authored in MagicaVoxel (`.vox`, read by our own importer).

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
- Headless runs use the Compatibility renderer, which looks brighter and more saturated
  than Forward+ on Mark's PC. Judge layout and shape from screenshots, not exact colour.
- Look at screenshots before saying visual work is done.
