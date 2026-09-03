# STRATCOM Mesh Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic multi-hop relay routing so CENTCOM can manage nodes through other STRATCOM bootstrap nodes.

**Architecture:** Replace direct modem-address command delivery with logical node-ID mesh envelopes on ports 4510/4511. Bootstrap nodes flood unseen envelopes with bounded TTL and dedupe, while CENTCOM originates/consumes envelopes and remains authoritative for deployment and operations.

**Tech Stack:** OpenComputers/OpenOS 1.8.7, Lua 5.3, HBM NTM integration, OpenComputers wireless modem.

**Spec:** `docs/superpowers/specs/2026-09-03-stratcom-mesh-routing-design.md`

## Global Constraints

- Preserve management port `4510` and operational port `4511`.
- Preserve central-controlled runtime deployment and existing runtime module interface.
- Use one serialized envelope argument per modem packet.
- Default TTL is 6 hops; dedupe entries expire after 30 seconds.
- Bootstrap remains manually installed; runtime remains centrally deployed.

---

### Task 1: Bootstrap mesh transport

**Files:**
- Modify: `bootstrap/bootstrap.lua`
- Modify: `bootstrap/version.txt`

**Interfaces:**
- Consumes modem messages shaped as `STRATCOM_NET, serialization.serialize(envelope)`.
- Produces relayed envelopes, logical management responses, and runtime responses.

- [ ] Add unique message-id generation, envelope validation, seen-cache pruning, send/broadcast helpers, and forwarding.
- [ ] Convert startup HELLO/HEARTBEAT to mesh envelopes targeting `CENTRAL`.
- [ ] Convert management execution to logical source/destination validation rather than modem hardware address.
- [ ] Convert runtime command/response transport to mesh envelopes on port 4511.
- [ ] Preserve Ctrl+C, deployment rollback, runtime start/stop/restart behavior.
- [ ] Set bootstrap version to `2.1.0`.

### Task 2: Central mesh transport

**Files:**
- Modify: `central/central.lua`
- Modify: `central/version.txt`

**Interfaces:**
- Consumes mesh envelopes destined for `CENTRAL`.
- Produces logical commands targeted by node ID and broadcast discovery packets.

- [ ] Add central message-id generation, envelope validation, dedupe, and broadcast send helpers.
- [ ] Register nodes by logical node ID instead of relying on modem hardware addresses.
- [ ] Route CLAIM, INFO, deployment, START/STOP/RESTART through mesh management envelopes.
- [ ] Route STATUS/PING/ARM/DISARM/LAUNCH through mesh operational envelopes.
- [ ] Preserve GitHub runtime sync, automatic reconciliation, console commands, and status display.
- [ ] Set central version to `2.1.0`.

### Task 3: Documentation and verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Documents bootstrap 2.1.0 migration and multi-hop behavior.

- [ ] Document that every relay participant must run bootstrap 2.1.0+.
- [ ] Document one-time manual bootstrap update commands for ABM-A1 and SILO-S1.
- [ ] Verify repository files contain version `2.1.0`, mesh marker `STRATCOM_NET`, TTL/dedupe logic, and logical destination handling.
- [ ] Perform static structural verification of generated Lua for balanced block structure and required protocol markers; final OpenComputers runtime verification remains in-game.
