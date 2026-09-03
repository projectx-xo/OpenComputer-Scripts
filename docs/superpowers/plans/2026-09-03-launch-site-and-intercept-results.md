# Launch-Site Inference and Intercept Results Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve automatic-defense outcome classification and derive persistent possible launch sites from radar track acquisition data.

**Architecture:** Keep radar nodes unchanged. CENTCOM records each missile track's first observed coordinates, evaluates early climb/departure behavior, merges nearby candidates into persistent launch-site records, and exposes them with `launchsites` / `launchsite <id>`. Defense outcome classification remains in CENTCOM and waits for a longer post-launch observation window before declaring a miss.

**Tech Stack:** OpenComputers Lua 5.3, existing STRATCOM mesh protocol, HBM `ntm_radar` track telemetry.

**Spec:** Approved in chat on 2026-09-03.

## Global Constraints

- Preserve existing bootstrap and runtime protocols.
- No automatic retaliation against inferred launch sites.
- Only radar types 0 through 9 are eligible missile tracks.
- Preserve the first observed X/Y/Z for each track even as the track moves.
- Keep current automatic ABM engagement behavior except for result-classification timing.

---

### Task 1: Intercept result classification

**Files:**
- Modify: `central/central.lua`

**Interfaces:**
- Consumes: existing `activeEngagements`, radar `TRACK_LOST` events.
- Produces: `INTERCEPT_CONFIRMED` on hostile track loss after ABM fire; `MISS` only after the extended observation window.

- [ ] Increase the post-launch hostile-track observation window.
- [ ] Change hostile-track loss after `FIRED`/`LAUNCHING` to `INTERCEPT_CONFIRMED`.
- [ ] Keep interceptor-track loss independent from hostile engagement state.
- [ ] Verify Lua syntax.

### Task 2: Possible launch-site inference

**Files:**
- Modify: `central/central.lua`

**Interfaces:**
- Consumes: radar track acquisition/update data.
- Produces: persistent `launchSites` records and `launchsites` / `launchsite <id>` commands.

- [ ] Preserve first-seen coordinates and velocity evidence on radar tracks.
- [ ] Detect low-altitude missile acquisition followed by sustained climb/departure.
- [ ] Merge candidates within a configurable horizontal distance.
- [ ] Track launches, first/last seen, confidence, station, and source track.
- [ ] Print `POSSIBLE LAUNCH SITE` when a candidate is promoted.
- [ ] Add operator commands and help text.
- [ ] Verify Lua syntax.

### Task 3: Release

**Files:**
- Modify: `central/version.txt`

- [ ] Bump CENTCOM version.
- [ ] Fetch the exact pushed files and verify constants, commands, and release version.
