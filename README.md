# OpenComputer Scripts

STRATCOM command-and-control software for OpenComputers + HBM Nuclear Tech.

## v2 architecture

Central is authoritative. Field nodes do **not** download runtime software from GitHub and do not decide when to start/update it.

```text
GitHub
  |
  v
CENTRAL STRATCOM
  |
  | management 4510
  | operations 4511
  v
NODE BOOTSTRAPS
  |
  v
centrally deployed role runtime
```

## Repository layout

```text
bootstrap/
├── bootstrap.lua
├── config.example.lua
└── version.txt

runtime/
├── manifest.lua
└── launchpad.lua

central/
├── central.lua
└── version.txt
```

The old `node/` directory is the legacy v1 agent and should not be used for new v2 nodes.

## Field node installation

A field computer needs:

- OpenOS
- modem / wireless network card
- HBM launch pad exposed as `ntm_launch_pad`
- Inventory Controller Upgrade if exact missile-name detection is desired
- **No Internet Card is required on the node**

Create the node configuration:

```sh
mkdir /home/stratcom
edit /home/stratcom/config.lua
```

Strike example:

```lua
return {
    id = "SILO-S1",
    role = "strike",
    managementPort = 4510,
    operationalPort = 4511,
    heartbeatInterval = 5,
}
```

Defense example:

```lua
return {
    id = "ABM-A1",
    role = "defense",
    managementPort = 4510,
    operationalPort = 4511,
    heartbeatInterval = 5,
}
```

Install the permanent bootstrap once:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/bootstrap/bootstrap.lua?install=200" /home/stratcom/bootstrap.lua
```

Start it:

```sh
lua /home/stratcom/bootstrap.lua
```

The node should display `Waiting for central command...`. Do not install or run `runtime/launchpad.lua` manually. Central deploys and starts it.

## Central installation

Central requires an Internet Card because it is the only machine that syncs runtime software from GitHub.

```sh
mkdir /home/stratcom
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/central/central.lua?install=200" /home/stratcom/central.lua
lua /home/stratcom/central.lua
```

On startup central:

1. checks for central-program updates;
2. downloads `runtime/manifest.lua`;
3. caches the desired runtime for each role;
4. discovers bootstrap nodes;
5. claims each node;
6. compares installed runtime version to the desired version;
7. automatically deploys missing/outdated runtime software;
8. starts the runtime.

## Central commands

```text
help
discover
nodes
info SILO-S1
sync
deploy SILO-S1
deploy all
start SILO-S1
stop SILO-S1
restart SILO-S1
status SILO-S1
ping SILO-S1
arm SILO-S1
disarm SILO-S1
launch SILO-S1 500 -250
clear
quit
```

## Runtime repository

`runtime/manifest.lua` declares the desired role software version. Current roles:

- `defense` -> `runtime/launchpad.lua`
- `strike` -> `runtime/launchpad.lua`

Changing a role's version in the manifest causes central to deploy that version to nodes when they connect/reconcile.

## Deployment safety

- Bootstrap accepts management/operational commands only from the central modem address that claimed it.
- Runtime is transferred in chunks over OpenComputers modem networking.
- Bootstrap validates incoming Lua with `loadfile` before installation.
- The previous runtime is retained as `runtime/previous.lua`.
- A failed validation does not replace the current runtime.
- Launch runtime requires `ARM` before `LAUNCH` and disarms after a successful launch.

## Migrating from v1 nodes

On each existing `ABM-A1`, `SILO-S1`, etc.:

1. stop/reboot the old `node.lua`;
2. keep or replace `/home/stratcom/config.lua` using the v2 format above;
3. download `bootstrap/bootstrap.lua`;
4. run `lua /home/stratcom/bootstrap.lua`;
5. do not start `node.lua` again.

After bootstrap is running, central owns runtime installation and lifecycle.
