# Automatic ABM Defense Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add conservative automatic interception of inbound radar tracks using `ABM-A1`.

**Architecture:** CENTCOM consumes existing RADAR_TRACK events, computes whether each eligible track intersects a configured protected circle, and sequences ARM -> LAUNCH against ABM-A1. The existing defense runtime remains unchanged.

**Tech Stack:** OpenComputers OpenOS 1.8.7, Lua 5.3, STRATCOM mesh protocol 2.

**Spec:** `docs/superpowers/specs/2026-09-03-automatic-abm-defense-design.md`

## Global Constraints

- Automatic defense defaults OFF after every CENTCOM restart.
- ABM node ID is `ABM-A1`.
- Automatic engagement only accepts HBM radar type IDs 0-9.
- Required ABM missile ID is `hbm:item.missile_anti-ballistic`.
- Existing strike, radar, mesh, deployment and manual defense commands must remain functional.

---

### Task 1: Defense state and threat geometry

**Files:**
- Modify: `central/central.lua`

- [ ] Add in-memory defense configuration and engagement state.
- [ ] Implement closest-approach geometry against the configured protection circle.
- [ ] Require repeated qualifying updates before creating an engagement.

### Task 2: ABM engagement state machine

**Files:**
- Modify: `central/central.lua`

- [ ] Validate ABM-A1 online/running/ready/missile state.
- [ ] Send ARM and wait for ACK.
- [ ] Send LAUNCH with a predicted X/Z intercept coordinate.
- [ ] Record launch result, track loss, miss timeout, and cooldown.

### Task 3: Operator controls

**Files:**
- Modify: `central/central.lua`
- Modify: `central/version.txt`

- [ ] Add `defense protect`, `defense auto`, `defense status`, and `engagements` commands.
- [ ] Show automatic-defense status in the CENTCOM header.
- [ ] Bump CENTCOM version.

### Task 4: Verification

- [ ] Verify repository source contains the required commands and constants.
- [ ] Verify existing radar/strike/deployment command surfaces remain present.
- [ ] Perform in-game test with automatic mode OFF first, then enable against a known test missile.
