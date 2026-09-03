# STRATCOM Radar Network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deployable `radar` node role that aggregates multiple HBM `ntm_radar` components and streams persistent radar tracks into STRATCOM Central.

**Architecture:** Each radar computer is one logical STRATCOM node (`RADAR-01`, `RADAR-02`, ...), and may have multiple physical HBM radar components. The radar runtime locally merges duplicate observations, tracks moving contacts with nearest-neighbor prediction, and emits station status plus `TRACK_ACQUIRED`, `TRACK_UPDATE`, and `TRACK_LOST` events over the existing runtime mesh. Central stores station status and active tracks by `<station>:<local-track-id>` and provides operator commands to inspect them.

**Tech Stack:** OpenComputers/OpenOS 1.8.7, Lua 5.3, HBM Nuclear Tech `ntm_radar`, existing STRATCOM mesh protocol 2.

**Spec:** Approved in chat on 2026-09-03: radar is detection/reporting only; automated ABM engagement is out of scope.

## Global Constraints

- Keep bootstrap protocol unchanged.
- Radar node IDs follow `RADAR-01`, `RADAR-02`, `RADAR-03`, ...
- One radar node may aggregate multiple `ntm_radar` components.
- Poll local radar components every 0.25 seconds.
- Merge same-cycle duplicate observations from multiple local radar components.
- Maintain persistent local track IDs with velocity prediction and a 2-second lost timeout.
- Preserve HBM radar type IDs and map 0-13 to readable names.
- Central must not auto-engage defensive launchers in this version.

---

### Task 1: Radar runtime

**Files:**
- Create: `runtime/radar.lua`

**Interfaces:**
- Consumes: existing bootstrap runtime context (`context.send`, `context.log`, role/id metadata)
- Produces: runtime responses `STATUS`, `RADAR_TRACK_ACQUIRED`, `RADAR_TRACK_UPDATE`, `RADAR_TRACK_LOST`

- [ ] Enumerate and sort all `ntm_radar` component addresses.
- [ ] Read station state via `getPos`, `getRange`, `getEnergyInfo`, `isJammed`, `getSettings`, `getAmount`, `getEntityAtIndex`.
- [ ] Merge duplicate observations from local radars within 10 blocks.
- [ ] Track contacts using nearest-neighbor predicted position, 350-block match threshold, and 2-second lost timeout.
- [ ] Emit acquired/update/lost events and return full station snapshot on `STATUS`.

### Task 2: Runtime manifest

**Files:**
- Modify: `runtime/manifest.lua`

**Interfaces:**
- Produces: `radar` role pointing to `runtime/radar.lua` with its own runtime version.

- [ ] Add `radar` role entry.
- [ ] Leave strike and defense role mappings unchanged.

### Task 3: Central radar ingestion and operator commands

**Files:**
- Modify: `central/central.lua`
- Modify: `central/version.txt`

**Interfaces:**
- Consumes: radar runtime `STATUS` and radar track events.
- Produces: `radars`, `radar <node>`, `tracks`, `tracks <node>` operator views.

- [ ] Store radar station snapshot on the node object.
- [ ] Maintain active global tracks keyed by station and local track ID.
- [ ] Remove tracks on `RADAR_TRACK_LOST` and mark stale tracks if station goes offline.
- [ ] Add readable radar type names and track fields (position, velocity, speed, heading, radars seeing contact, age).
- [ ] Add operator commands and help text.
- [ ] Keep the existing 5-second runtime status polling so radar station state refreshes automatically.

### Task 4: Verification

**Files:**
- Verify: `runtime/radar.lua`
- Verify: `runtime/manifest.lua`
- Verify: `central/central.lua`
- Verify: `central/version.txt`

- [ ] Confirm repository files contain the new role and commands.
- [ ] Verify Lua syntax where possible.
- [ ] In-game: bootstrap a node with `id = "RADAR-01", role = "radar"`, run Central `sync`, confirm runtime deployment, then launch a detectable missile and verify `tracks` shows a persistent track.
