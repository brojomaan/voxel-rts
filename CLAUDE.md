# Two Billion Presents (TinyTapTowns)

A Christmas incremental city builder in **Godot 4.7.1** (GDScript), by Mark Silvester /
Pickle Plum Studios. The project is in `tap-towns/`. Elves gather, carry and craft in a
3D town drawn as pixel art; the goal is two billion presents by Christmas (the demo
stops at 1 million). Releasing on Steam and itch.io.

## How we work

- **Pull before anything** (`git pull --rebase origin main`). Mark makes art and scenes
  in parallel and pushes often.
- Make the change in the repo, test it headless, then commit and push to `main` while
  Mark playtests. Small, focused commits with a message that says what changed and why.
- **Never touch `UI/Mock/`**: those are Mark's mock-ups. Don't overwrite his art or scenes
  wholesale; edit only the nodes a change needs.
- If Mark says "no need to do anything, just so you're aware", don't act.
- Mark understands the code and likes to know *why*: explain design choices briefly,
  flag trade-offs, and say when something was left out or is a guess.

## GDScript style

- **Explicit types everywhere**, never `:=`: `var speed: float = 1.3`,
  `for elf: Elf in elves:`, `func get_cost() -> int:`. (The project warns on untyped and
  inferred declarations.)
- Doc comments (`##`) on classes and exported settings, written plainly, saying what
  it's for and any gotcha. Comments explain why, not what.
- Architecture: **services** (autoloads in `Scripts/Services/`, e.g. `ResourceService`,
  `TechService`, `TutorialService`), **components** (`Scripts/Components/`, one job each,
  found by type), **bases** (`Scripts/Bases/`, e.g. `BuildingBase`). Input goes through
  `InteractionService` / `GamepadService`, not scattered `_input`s.
- **Data lives in resources** (`.tres`) so Mark can tune in the Inspector: buildings
  (`Buildings/BuildingData`, `BuildingOptions`), upgrades, the tech tree, the tutorial
  (`Levels/tutorial.tres`), credits (`UI/credits.tres`), achievements
  (`Achievements/achievements.tres`). Prefer adding a field to a resource over a
  hard-coded number.
- Player-facing text: short, friendly, British English, straight quotes (the pixel fonts
  have no curly quotes).

## UI

- HUD is pixel UI on `PixelCanvas` layers (whole-number scaling, about 480x270 UI pixels
  at Large on 1080p). Sizes are in UI pixels. The title screen is always Large;
  in-game follows the UI Size setting (Medium default).
- Colours: `UiColors` (TEXT, GOLD, GOOD, BAD, DIM). Icons: `UiIcons` (16px cells on
  `UI/UI_Sheet_01.png`; upgrades use rows 5 to 8 via `icon_cell`).
- Tooltips: `UiTooltip.attach(control, provider)`; the provider returns
  `{title, value, value_color, rows: [{icon, text, color}], footer}`. Rows don't wrap,
  footers do.
- Pop-ups extend `PixelPopup`; Tinsel (the tutorial elf) is `TinselPopup`.
- Progress bars are `CandyBar` (candy cane for production, wood stripes for building).

## Testing (headless)

Godot 4.7.1 Linux build at `/tmp/godot/Godot_v4.7.1-stable_linux.x86_64` (download it if
missing). From `tap-towns/`:

```
# after adding a class_name or new PNGs
/tmp/godot/Godot_v4.7.1-stable_linux.x86_64 --headless --import
# run a test script (extends SceneTree) with rendering, for screenshots
xvfb-run -a -s "-screen 0 1920x1080x24" /tmp/godot/Godot_v4.7.1-stable_linux.x86_64 \
  --rendering-driver opengl3 --resolution 1920x1080 --script res://zz_t.gd
```

- Test scripts are named `zz_*.gd` and **deleted before committing**.
- They mustn't name autoload-dependent classes at compile time: use
  `root.get_node("ResourceService")`, `call()`, `get()`, `load()`.
- A script error leaves Godot hanging without quitting; run with a `timeout`, and add
  `--verbose` to find the error.
- The outline shader is Forward+ only, so it errors on opengl3; that's expected.
- Load `res://game.tscn` for the game; `ResourceService.cheat_set(id, amount)` sets stock.
- Look at screenshots before saying UI work is done.

## Handy tools and notes

- `Tools/icon_renderer.tscn`: renders building pictures and portraits from the 3D
  models ("Render Icons"). Re-run after new or changed buildings.
- `Tools/achievement_icon_maker.tscn`: 64x64 Steam achievement icons plus locked copies.
- GIF recorder (`GifRecorder`): F9, Ctrl+F9 (with UI), Shift+F9 (timelapse); itch-sized.
- Links (Steam, feedback form, Discord) are in `Scripts/Services/game_links.gd`; empty
  links hide their buttons in release builds.
- Demo vs full game: `GameService.is_demo()`. Achievements are off in the demo.
- Design notes: `TUNING.md` (balance), `UPGRADE_ICONS.md`, `ACHIEVEMENTS.md`.
