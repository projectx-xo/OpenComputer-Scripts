# Friendly Outbound IFF Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent automatic defense from engaging STRATCOM-issued outbound missiles by correlating radar tracks with recent commanded launches.

**Architecture:** Keep all IFF state in `central/central.lua`. Strike/manual launch commands register short-lived friendly expectations; radar track updates geometrically match those expectations and persist a friendly classification on the track. Friendly tracks are excluded from ABM and launch-site logic.

**Tech Stack:** OpenComputers Lua 5.3, existing STRATCOM mesh/runtime protocol.

**Spec:** `docs/superpowers/specs/2026-09-04-friendly-iff-design.md`

## Global Constraints

- Only STRATCOM-issued launches create friendly expectations.
- Default expectation lifetime: 30 seconds.
- Heading tolerance: 30 degrees.
- Track must originate inside the configured protected region and be moving outward.
- Friendly tracks remain friendly for the lifetime of that radar track.
- No changes to radar, strike, defense, or bootstrap runtimes.

---

### Task 1: Friendly expectation state and geometry

**Files:**
- Modify: `central/central.lua`

- [ ] Add expectation table/counter and constants.
- [ ] Add angle normalization, bearing, protected-region-origin, and outward-motion helpers.
- [ ] Add registration/expiry/matching helpers.
- [ ] Preserve friendly metadata when radar track updates replace track snapshots.

### Task 2: Register outbound missions

**Files:**
- Modify: `central/central.lua`

- [ ] Register one friendly expectation after confirmed manual strike-node launch submission.
- [ ] Register a salvo expectation after confirmed `strike` submission, using the selected launcher count.
- [ ] Do not register expectations for defense-node launches or aborted commands.

### Task 3: Apply IFF to radar and defense

**Files:**
- Modify: `central/central.lua`

- [ ] Match missile tracks against expectations on ACQUIRED/UPDATE.
- [ ] Mark matched tracks `FRIENDLY_OUTBOUND` with source/target metadata.
- [ ] Exclude friendly tracks from `evaluateTrackForDefense`.
- [ ] Exclude friendly tracks from launch-site promotion.
- [ ] Expire expectations from the existing periodic timer path.

### Task 4: Operator visibility and release

**Files:**
- Modify: `central/central.lua`
- Modify: `central/version.txt`

- [ ] Show IFF state/source/mission target in `tracks`.
- [ ] Add expectation count/details to `defense status` or header diagnostics.
- [ ] Bump CENTCOM release version.
- [ ] Verify exact pushed source contains all IFF surfaces and release version.
