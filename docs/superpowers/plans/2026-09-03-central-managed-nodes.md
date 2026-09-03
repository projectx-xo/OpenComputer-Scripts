# Central-Managed STRATCOM Nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make central STRATCOM the authoritative software/deployment controller while field nodes run a minimal bootstrap and centrally supplied runtime.

**Architecture:** Management runs on port `4510`, operations on `4511`. Bootstrap owns the event loop and deployment lifecycle; role runtimes are modules loaded by bootstrap. Central syncs the desired role runtime from GitHub and reconciles every node automatically.

**Tech Stack:** Minecraft 1.7.10 OpenComputers/OpenOS Lua, HBM NTM OpenComputers components, modem networking, GitHub raw content from the central computer only.

**Spec:** `docs/superpowers/specs/2026-09-03-central-managed-nodes-design.md`

## Global Constraints

- Field nodes must not require Internet Cards after bootstrap installation.
- `config.lua` must never be overwritten by deployment.
- Only the claimed central modem address may manage or operate a node.
- Failed runtime deployment must preserve the previous valid runtime.
- Management port is `4510`; operational port is `4511`.
- Existing launch safety behavior remains: explicit ARM before LAUNCH and automatic disarm after successful launch.

---

### Task 1: Bootstrap agent

**Files:**
- Create: `bootstrap/bootstrap.lua`
- Create: `bootstrap/version.txt`

**Interfaces:**
- Consumes: `/home/stratcom/config.lua`
- Produces: `BOOT_HELLO`, `BOOT_HEARTBEAT`, management command handling, runtime module lifecycle.

- [ ] Implement node identity/config loading and modem setup.
- [ ] Implement central claim and sender filtering.
- [ ] Implement deployment begin/chunk/commit with `loadfile` validation and rollback.
- [ ] Implement start/stop/restart runtime lifecycle.
- [ ] Forward only central-originated `CMD` packets on port `4511` to runtime.
- [ ] Keep local Ctrl+C shutdown support.

### Task 2: HBM launch-pad runtime

**Files:**
- Create: `runtime/launchpad.lua`
- Create: `runtime/manifest.lua`

**Interfaces:**
- Consumes: bootstrap runtime context.
- Produces: `STATUS`, `ACK`, `ERROR`, `LAUNCH_RESULT`, missile inventory details.

- [ ] Implement `start`, `stop`, `tick`, `onMessage`, and `status` interface.
- [ ] Discover `ntm_launch_pad` and optional `inventory_controller`.
- [ ] Auto-detect adjacent 7-slot launcher inventory and read slot 1.
- [ ] Preserve ARM/DISARM/LAUNCH safety behavior.
- [ ] Map both `defense` and `strike` roles to launchpad runtime version `2.0.0` in manifest.

### Task 3: Central software controller

**Files:**
- Replace: `central/central.lua`
- Update: `central/version.txt`

**Interfaces:**
- Consumes: bootstrap telemetry and runtime operational responses.
- Produces: automatic claim/reconcile/deploy/start plus operator CLI.

- [ ] Keep central self-update and GitHub cache busting.
- [ ] Sync/copy role runtime files from GitHub to central local repository cache.
- [ ] Register `BOOT_HELLO`/`BOOT_HEARTBEAT` nodes.
- [ ] Claim nodes and automatically reconcile desired runtime versions.
- [ ] Chunk runtime files into 2048-byte deployment packets.
- [ ] On successful deployment, automatically start the runtime.
- [ ] Add CLI: `nodes`, `info`, `deploy`, `start`, `stop`, `restart`, `status`, `arm`, `disarm`, `launch`, `sync`, `discover`.

### Task 4: Migration and documentation

**Files:**
- Create: `bootstrap/config.example.lua`
- Update: `README.md`

**Interfaces:**
- Produces: one-time installation instructions for existing ABM/strike nodes and central.

- [ ] Document node bootstrap install and config.
- [ ] Document that nodes no longer need Internet Cards.
- [ ] Document central startup and automatic deployment flow.
- [ ] Document how to migrate existing `node.lua` sites to `bootstrap.lua`.

### Verification

Because OpenComputers/OpenOS is not available in this execution environment, in-game verification is required:

1. Start central and one bootstrap node.
2. Confirm central claims the node.
3. Confirm central deploys runtime `2.0.0` automatically.
4. Confirm bootstrap reports runtime `running`.
5. Confirm `status`, `arm`, `disarm`, and launch gating operate through port `4511`.
6. Start a second node and verify no node-to-node feedback loop.
7. Change runtime manifest version and confirm central redeploys the updated runtime without node Internet access.
