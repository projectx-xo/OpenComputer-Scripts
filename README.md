# OpenComputer Scripts

OpenComputers scripts for an HBM Nuclear Tech command-and-control network.

## Layout

- `node/node.lua` — reusable field-node daemon for launch-pad sites such as `ABM-A1`
- `central/central.lua` — central STRATCOM command console

## Network protocol

Port: `4510`

Field nodes support:

- `PING`
- `STATUS`
- `IDENTIFY`
- `ARM`
- `DISARM`
- `LAUNCH <x> <z>`
- `SHUTDOWN_NODE`

Nodes broadcast `HELLO` on startup and `HEARTBEAT` every 5 seconds.

## Install on a field node

```sh
mkdir /home/stratcom
wget -f https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/node/node.lua /home/stratcom/node.lua
lua /home/stratcom/node.lua
```

Edit the node identity near the top of `node.lua` for each site:

```lua
local NODE_ID = "ABM-A1"
local NODE_ROLE = "defense"
```

## Install on the central computer

```sh
mkdir /home/stratcom
wget -f https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/central/central.lua /home/stratcom/central.lua
lua /home/stratcom/central.lua
```

Central commands:

```text
help
discover
nodes
status ABM-A1
ping ABM-A1
arm ABM-A1
disarm ABM-A1
launch ABM-A1 500 -250
clear
quit
```

The current field-node implementation expects an HBM component named `ntm_launch_pad` and an OpenComputers modem.
