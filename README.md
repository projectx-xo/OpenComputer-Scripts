# OpenComputer Scripts

STRATCOM command-and-control software for OpenComputers + HBM Nuclear Tech.

## v2.1 architecture

Central is authoritative. Field nodes do **not** download runtime software from GitHub and do not decide when to start/update it.

STRATCOM 2.1 adds automatic multi-hop wireless routing. A field node no longer needs a direct radio path to CENTCOM as long as another 2.1+ bootstrap can hear both sides.

```text
GitHub
  |
  v
CENTRAL STRATCOM
  |
  | wireless mesh
  v
ABM-A1  <---->  SILO-S1  <---->  RADAR-1
  |                 |
  v                 v
runtime           runtime
```

Management traffic uses port `4510`; operational traffic uses port `4511`. Both ports carry serialized `STRATCOM_NET` envelopes with logical source/destination node IDs, a message ID, and a bounded TTL. Each bootstrap forwards an unseen envelope once, so loops are suppressed automatically.

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
    meshTtl = 6,
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
    meshTtl = 6,
}
```

Install/update the permanent bootstrap:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/bootstrap/bootstrap.lua?install=210" /home/stratcom/bootstrap.lua
```

Start it:

```sh
lua /home/stratcom/bootstrap.lua
```

The header should show `Bootstrap: 2.1.0` and `Mesh: protocol 2 / TTL 6`. Do not install or run `runtime/launchpad.lua` manually. Central deploys and starts it.

## Important v2.1 mesh migration

Every computer that must **relay** traffic needs bootstrap `2.1.0` or newer. For the SILO-S1-through-ABM-A1 topology, update both `ABM-A1` and `SILO-S1` to bootstrap 2.1.0 before testing discovery.

Existing runtime `2.0.0` is compatible and does not need to be manually reinstalled.

## Central installation

Central requires an Internet Card because it is the only machine that syncs runtime software from GitHub.

```sh
mkdir /home/stratcom
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/central/central.lua?install=210" /home/stratcom/central.lua
lua /home/stratcom/central.lua
```

The header should show `Version: 2.1.0` and `Mesh: protocol 2 / TTL 6`.

On startup central:

1. checks for central-program updates;
2. downloads `runtime/manifest.lua`;
3. caches the desired runtime for each role;
4. broadcasts mesh discovery;
5. discovers nodes directly or through relays;
6. claims each node by logical node ID;
7. compares installed runtime version to the desired version;
8. automatically deploys missing/outdated runtime software through the mesh;
9. starts the runtime.

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

## Mesh protocol

Wire format on both modem ports:

```text
STRATCOM_NET | <serialized envelope>
```

Envelope fields:

```lua
{
    protocol = 2,
    id = "unique-message-id",
    source = "CENTRAL" or "SILO-S1",
    destination = "CENTRAL" or node id or "*",
    ttl = 6,
    kind = "MGMT" or "CMD" or response type,
    payload = { ... },
}
```

Bootstraps keep a short-lived cache of message IDs. Packets already seen are dropped; unseen packets not addressed to the local node are rebroadcast with TTL reduced by one. This allows automatic relay without configuring static routes.

## Runtime repository

`runtime/manifest.lua` declares the desired role software version. Current roles:

- `defense` -> `runtime/launchpad.lua`
- `strike` -> `runtime/launchpad.lua`

Changing a role's version in the manifest causes central to deploy that version to nodes when they connect/reconcile.

## Deployment safety

- Bootstrap accepts management/operational execution only when the logical source is `CENTRAL`.
- Commands are addressed to a logical node ID, not a modem hardware address.
- Runtime is transferred in chunks over the mesh.
- Bootstrap validates incoming Lua with `loadfile` before installation.
- The previous runtime is retained as `runtime/previous.lua`.
- A failed validation does not replace the current runtime.
- Launch runtime requires `ARM` before `LAUNCH` and disarms after a successful launch.

## Migrating from v1/v2.0 nodes

On each existing `ABM-A1`, `SILO-S1`, etc.:

1. stop/reboot the old program;
2. keep `/home/stratcom/config.lua` (the legacy `port = 4510` form is still accepted);
3. download bootstrap 2.1.0 using the command above;
4. run `lua /home/stratcom/bootstrap.lua`;
5. do not start legacy `node.lua` again.

After bootstrap is running, central owns runtime installation and lifecycle. Bootstrap updates remain deliberate/manual because bootstrap is the recovery/control layer itself.
