# Multi-Launcher Strike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic multi-launcher support for strike nodes while preserving existing single-launcher defense behavior.

**Architecture:** Create a dedicated `runtime/strike.lua` that enumerates all launch pads and inventory controllers, exposes per-launcher status, and accepts launcher-targeted ARM/DISARM/LAUNCH commands. Update CENTCOM to render launcher arrays and send launcher selectors. Update the runtime manifest so strike nodes auto-deploy the new runtime.

**Tech Stack:** OpenComputers OpenOS 1.8.7, Lua 5.3, HBM NTM `ntm_launch_pad`, Inventory Controller, STRATCOM mesh protocol.

**Spec:** `docs/superpowers/specs/2026-09-03-multi-launcher-strike-design.md`

## Global Constraints
- Preserve defense-node compatibility.
- No `launch all` command.
- Launcher numbering is deterministic by sorted component address.
- Strike runtime is centrally deployed via existing ACK/retry deployment.

---

### Task 1: Multi-launcher strike runtime

**Files:**
- Create: `runtime/strike.lua`

**Interfaces:**
- Consumes runtime context `ctx.send`, `ctx.log`, `ctx.id`, `ctx.role`.
- Produces `start`, `stop`, `tick`, `status`, `onMessage` runtime interface.

- [ ] Enumerate/sort launch-pad and inventory-controller component addresses.
- [ ] Pair them by deterministic index.
- [ ] Implement per-launcher missile scan and `UNLOADED` detection.
- [ ] Implement independent armed state per launcher.
- [ ] Implement `STATUS`, `ARM <n|all>`, `DISARM <n|all>`, `LAUNCH <n> <x> <z>`.

### Task 2: CENTCOM multi-launcher presentation and commands

**Files:**
- Modify: `central/central.lua`
- Modify: `central/version.txt`

**Interfaces:**
- Consumes `status.launchers` array from strike runtime.
- Produces launcher-aware `status`, `arm`, `disarm`, and `launch` CLI behavior.

- [ ] Store `status.launchers` and launcher count.
- [ ] Render per-launcher details in `status <node>`.
- [ ] Accept launcher selector for arm/disarm and launcher number for launch.
- [ ] Keep legacy single-launcher commands working for defense nodes.

### Task 3: Runtime manifest

**Files:**
- Modify: `runtime/manifest.lua`

- [ ] Point `strike` to `runtime/strike.lua` and bump strike runtime version.
- [ ] Leave defense on `runtime/launchpad.lua`.
