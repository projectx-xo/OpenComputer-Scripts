# STRATCOM Reliability Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development. The existing user approval covers this design.

**Goal:** Implement all six approved startup, update, operator workflow, telemetry, performance and scan improvements.
**Architecture:** Stable RC supervisor plus versioned application bundles; retain the existing mesh protocol and modular node runtimes. A console submits commands to a running service through a local queue.
**Tech Stack:** OpenOS, Lua 5.2+, Minecraft OpenComputers.
**Spec:** docs/superpowers/specs/2026-09-04-reliability-design.md

## Global Constraints
- Keep protocol 2 and existing command compatibility where possible; optional trailing request/transaction IDs permit legacy responses.
- Keep configuration and operator intent outside release bundles. Do not replay launches or persist armed state.
- No reboot for program updates. Offline boot must require no HTTP calls.
- Tests execute production functions/chunks with hardware boundary stubs and literal expected outcomes.
- Shared workspace: each worker owns only its assigned files and tests; root integrates versions/docs. No pushes to shared main during implementation.

## Task 1: Node lifecycle and deployment
Files: bootstrap/bootstrap.lua; tests/bootstrap_test.lua.
Interface: optional service options from the spec. ctx.config supplies config; ctx.saveConfig persists config; ctx.session identifies each runtime start. STATUS response token support is implemented by bootstrap intercepting STATUS and invoking runtime.status(detail).
- [x] Write failing deployment tests: transfer retains old runtime; malformed/aborted/timed-out transfer cleans up; candidate start failure restores old file/version/running state; duplicate commit yields prior result; STOP survives restart.
- [x] Implement transactional staging, checks and rollback, previous version metadata, persistent running/stopped/maintenance state, cleanup of failed module start, independent timeouts.
- [x] Add service queue integration, graceful stop and ready callback after bootstrap startup, and local runtime commands (status/doctor/scan delegated to runtime).
- [x] Test and review the concrete behavior. Report protocol additions to root for CENTRAL integration.

## Task 2: CENTRAL lifecycle, commands and deployment coordination
Files: central/central.lua; tests/central_test.lua.
- [x] Write failing tests for stopped reconciliation, cache retention, stale/duplicate samples, command response correlation and service detach.
- [x] Remove rebooting self-update; load bundled runtime manifest before discover and signal ready without GitHub. Integrate service command queue and buffered logs.
- [x] Persist node intent/aliases and defense configuration. Correlate STATUS responses; timeout explicitly. Serialize deployments and add transaction IDs; bound maintenance work and prune messages on timer.
- [x] Reject stale/duplicate radar observations and separate runtime sessions. Label lost contact unconfirmed.
- [x] Add native scan, doctor, hardware mapping and maintenance commands. Verify behavior in the Lua harness.

## Task 3: Runtime telemetry, inventory and satellite
Files: runtime/strike.lua; runtime/radar.lua; runtime/intel.lua; tests/runtime_test.lua.
- [x] Test explicit mapping and cache invalidation; implement saved launcher labels/address/side/slot mappings and no unsafe index pairing for ambiguous inventories.
- [x] Test radar session/sequence and summary status without duplicate full tracks; implement optional full snapshots and hardware refresh.
- [x] Verify HBM satellite callback signatures in fork; test COMBINED_INTEL gating, scan progress, paginated results and disconnected relay errors; implement intel runtime.

## Task 4: Installer, supervisor, update recovery and console
Files: install.lua; service/stratcom.lua; service/rc.lua; service/console.lua; service/update.lua; tests/service_test.lua; release.lua; tools/make_release.py.
- [x] Test offline startup, console detachment, crash backoff, interrupted download, startup rollback and config-preserving install.
- [x] Implement stable service module, detached app worker, bounded logs/command queue, explicit stop, and application restart.
- [x] Stage complete versioned bundles using a pinned release URL and size/checksum validation. Activate only complete bundles; retain previous pointer; health-confirm activation and rollback on failure.
- [x] Implement one-command central/node install, enable RC, and console update/status/logs/doctor operations. Keep source URL configurable for local tests and branch installation.

## Task 5: Integration, release and documentation
Files: README.md; CHANGELOG.md; runtime/manifest.lua; version files; CI test workflow.
- [ ] Run all tests and Lua 5.2 syntax checks. Review cross-file queue/token/deployment contracts with a fresh reviewer and fix findings.
- [ ] Update version metadata and release manifest after final code. Provide a distributable bundle and verified install/migration steps.
- [ ] Commit implementation and create a reviewable draft PR where repository access allows; do not merge an untested live-server change into main.
