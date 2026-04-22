# Polar Channel Array

Altium DelphiScript that arranges multi-channel components into a circular pattern around a user-chosen origin.

![Before and after](images/before-after.svg)

## What it does

Takes a set of component classes that share a common prefix (e.g. `U_DUTB`, `U_DUTC`, `U_DUTD`...) and arranges them evenly around a polar origin. The first class alphabetically is the reference — it stays put. All others are copies of the reference's position, rotated around the origin by `i × (360°/N)`.

Moves components, tracks, vias, arcs, fills, text, and free pads. Does not move polygons or room rectangles.

![Rotation concept](images/rotation-concept.svg)

## Usage

![Workflow](images/workflow.svg)

1. Lay out the reference channel (first alphabetically) exactly where you want it on the ring.
2. Open the PCB. `File → Run Script… → Browse` → pick `PolarChannelArray.pas`.
3. Select `ArrangeChannelsInPolarArray` from the list.
4. Pick the prefix from the inventory dialog (auto-suggested).
5. Click the polar origin on the PCB (snaps to your Polar Grid if one is active).
6. Confirm the summary.
7. `Tools → Polygon Pours → Repour All`, then run DRC.

## Requirements

- Altium Designer 20 or newer (tested on 25).
- A multi-channel design where component classes have been generated (should be automatic if you compiled from a multi-channel schematic).
- The first channel alphabetically must already be placed correctly — its position and orientation define the template.

## Parameters

The script prompts for:

| Input | Description |
|---|---|
| Prefix | Common prefix of the channel classes (e.g. `U_DUT`) |
| Origin | Clicked on the PCB, or typed as X/Y in mm |

Radius and angular step are derived automatically from the reference channel's position and the number of matched channels.

## Limitations

- Polygons aren't transformed — repour after running.
- Room rectangles aren't moved — update manually via `Design → Rooms` if you use them.
- Dialog boxes may appear on a different monitor than Altium on multi-monitor setups. Click the Altium window before running to bias the first dialog.
- Undo works via `PCBServer.PreProcess/PostProcess`, but save the board first as a safety net.

## Files

- `PolarChannelArray.pas` — the script.
- `images/` — diagrams used in this README.

## Troubleshooting

**"No component classes found on this board"** — the schematic wasn't compiled with component class generation, or the board was created without multi-channel rooms. Run `Design → Update PCB Document` with class generation enabled.

**"Only 0 channel(s) matched prefix"** — the prefix doesn't match any class names. Check the inventory list shown in the first dialog for actual class names.

**Stragglers left behind after running** — free primitives (tracks, vias) that belonged to a channel but sat outside the channel's component bounding box. The script uses a 25% expanded bbox (min 5 mm, max 50 mm) to catch them. Increase `MARGIN_FRACTION` in the script constants if needed.

**Reference channel moved when it shouldn't have** — it shouldn't. The loop starts at `i := 1` and explicitly skips the reference. If this happens, report with before/after screenshots.