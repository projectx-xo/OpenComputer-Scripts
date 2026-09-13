# MAVEN responsive display

MAVEN is a read-only tactical telemetry display for the existing STRATCOM mesh. It does not replace Central and does not send operational commands. It listens to the same STRATCOM network traffic and renders the state it can observe on an OpenComputers screen.

## Display behavior

The renderer detects the bound OpenComputers screen with `gpu.getSize()` and reads the maximum character resolution with `gpu.maxResolution()`.

Automatic mode chooses a logical width that follows the physical panel aspect ratio. OpenComputers character cells are approximately twice as tall as they are wide, so the target is roughly:

```text
logicalWidth = logicalHeight * 2 * (screenBlocksWide / screenBlocksHigh)
```

The result is clamped to the GPU/screen maximum.

Typical Tier 3 targets:

| Physical screen | Automatic target |
| --- | --- |
| 1x1 | about 100x50 |
| 2x2 | about 100x50 |
| 3x3 | about 100x50 |
| 3x2 | about 150x50 |
| wide panel | up to 160x50 |

This prevents a square 3x3 wall from simply stretching a 160x50 workstation layout across the glass.

## Pages

The dashboard currently provides four responsive views:

1. **COP** — common operating picture with observed assets, a track map, and a selected-track inspector.
2. **TRACKS** — dense live track table.
3. **ASSETS** — observed STRATCOM nodes and runtime/link state.
4. **NETWORK** — modem, ports, panel size, chosen resolution, and layout profile.

The wide layout uses left/center/right panes. Narrow layouts collapse toward a map-first presentation so the same program remains usable across different screen shapes.

## Controls

```text
1   COP
2   TRACKS
3   ASSETS
4   NETWORK
Q   exit dashboard
```

Tier 2/3 touch screens can also select the top tabs and track entries directly.

## Install

MAVEN needs:

- OpenOS
- a GPU and bound screen
- a modem able to hear the STRATCOM mesh
- `maven.lua`
- `dashboard.lua`

Suggested locations:

```text
/home/maven/maven.lua
/home/maven/dashboard.lua
```

Copy `maven/maven.lua` to `/home/maven/maven.lua` and `central/dashboard.lua` to `/home/maven/dashboard.lua`.

Then run:

```sh
lua /home/maven/maven.lua
```

Optional layout overrides:

```sh
lua /home/maven/maven.lua auto
lua /home/maven/maven.lua wall
lua /home/maven/maven.lua wide
lua /home/maven/maven.lua compact
```

`auto` is recommended for normal use.

## Network behavior

MAVEN is passive. It opens STRATCOM management and operational ports and observes traffic that reaches its modem. It de-duplicates mesh envelopes by message ID so relayed copies are not rendered repeatedly.

It learns node metadata from bootstrap hello/heartbeat traffic and radar state from runtime status/track events. Because it is read-only, the existing Central remains authoritative and no field-node deployment changes are required.

If the MAVEN computer is placed near Central, it should see the same final-hop mesh traffic Central receives. A remote display can also work anywhere it can hear the relevant STRATCOM relay traffic.

## Rendering/performance

The dashboard redraws at a limited cadence rather than every game tick. It uses one GPU surface, background-filled panels, character-cell symbols, and touch hit regions; it does not create per-track background processes or additional network traffic.

On exit, the renderer restores the previous terminal resolution and colors.
