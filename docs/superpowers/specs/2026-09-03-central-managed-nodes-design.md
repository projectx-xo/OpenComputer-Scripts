# Central-Managed STRATCOM Nodes Design

## Goal

Replace self-managing field nodes with a tiny permanent bootstrap controlled by the central STRATCOM computer. Field nodes no longer access GitHub or decide when to update/start runtime software.

## Architecture

- Central owns repository sync, desired runtime versions, deployment, start/stop/restart, and operational commands.
- Each field computer permanently stores only `bootstrap.lua`, `config.lua`, and the currently deployed runtime.
- Central uses management port `4510`; runtime operational traffic uses port `4511`.
- Bootstrap accepts management commands only from the claimed central modem address.
- Runtime packets are forwarded only when they come from the claimed central modem address.

## Node filesystem

```text
/home/stratcom/
├── bootstrap.lua
├── config.lua
└── runtime/
    ├── current.lua
    ├── previous.lua
    └── version.txt
```

`config.lua` contains node identity and role. It is never overwritten by central deployment.

## Bootstrap protocol

Node broadcasts:

- `BOOT_HELLO, nodeId, role, bootstrapVersion, runtimeVersion, runtimeState`
- `BOOT_HEARTBEAT, nodeId, role, bootstrapVersion, runtimeVersion, runtimeState`

Central claims the node with:

- `MGMT, CLAIM`

After claim, bootstrap accepts only central-originated management packets:

- `INFO`
- `DEPLOY_BEGIN(version, totalChunks)`
- `DEPLOY_CHUNK(index, data)`
- `DEPLOY_COMMIT(version)`
- `START`
- `STOP`
- `RESTART`

Deployment writes to a temporary runtime file, validates it with `loadfile`, rotates `current.lua` to `previous.lua`, installs the new file, records the version, and reports success. Failed validation leaves the previous runtime intact.

## Runtime interface

A runtime file returns a table implementing:

```lua
runtime.start(context)
runtime.stop()
runtime.tick()
runtime.onMessage(remoteAddress, command, arg1, arg2)
runtime.status()
```

Bootstrap owns the event loop. It forwards operational packets on port `4511` to the loaded runtime.

## Runtime repository

Central downloads `runtime/manifest.lua` from GitHub and caches each role's desired runtime locally. Manifest entries map roles to a desired version and source file. Central auto-deploys mismatched or missing runtimes when a node connects.

## Reconciliation

When a node connects:

1. Central claims it.
2. Central compares installed runtime version with the desired role version.
3. If different, central deploys the desired runtime.
4. After deployment succeeds, central starts the runtime.
5. If versions match but runtime is stopped, central starts it.

## Safety

- Nodes do not download code from the Internet.
- Runtime deployment is accepted only from the claimed central modem address.
- A failed runtime deployment does not overwrite the last valid runtime.
- Runtime launch logic retains software ARM/DISARM gating and disarms after successful launch.
- Bootstrap ignores unrelated node traffic, preventing node-to-node feedback loops.

## Initial supported roles

- `defense`
- `strike`

Both initially use the HBM launch-pad runtime. The runtime detects `ntm_launch_pad`, optionally detects the adjacent 7-slot launcher inventory via `inventory_controller`, and reports exact missile item/label when available.
