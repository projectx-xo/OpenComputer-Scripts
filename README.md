# OpenComputer Scripts

OpenComputers scripts for an HBM Nuclear Tech command-and-control network.

## Layout

- `node/node.lua` — reusable field-node daemon for defense and strike launch-pad sites
- `node/config.example.lua` — example persistent defense-site configuration
- `node/config.strike.example.lua` — example persistent strike-site configuration
- `node/version.txt` — node release version used by the self-updater
- `central/central.lua` — central STRATCOM command console
- `central/version.txt` — central release version used by the self-updater

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

Nodes broadcast `HELLO` on startup and `HEARTBEAT` every 5 seconds. Central automatically requests full status on discovery and refreshes full status periodically.

## Field node install

Create the persistent site config first:

```sh
mkdir /home/stratcom
edit /home/stratcom/config.lua
```

Defense example:

```lua
return {
    id = "ABM-A1",
    role = "defense",
    port = 4510,
}
```

Strike example:

```lua
return {
    id = "SILO-S1",
    role = "strike",
    port = 4510,
}
```

Then install the reusable node program:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/node/node.lua?install=1" /home/stratcom/node.lua
lua /home/stratcom/node.lua
```

The config file is never replaced by software updates, so the same `node.lua` can be deployed to every launch site.

## Exact missile detection

If a field node has an OpenComputers **Inventory Controller Upgrade** attached through the Adapter, `node.lua` automatically scans sides 0-5 for the HBM launch pad's 7-slot inventory and reads slot 1.

The full status packet then includes:

- exact item ID, e.g. `hbm:item.missile_drill`
- display label, e.g. `The Concrete Cracker`
- stack count

Central displays the missile label in `nodes` and shows both label and item ID in `status <node>`.

## Central install

```sh
mkdir /home/stratcom
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/central/central.lua?install=1" /home/stratcom/central.lua
lua /home/stratcom/central.lua
```

Central commands:

```text
help
discover
nodes
status SILO-S1
ping SILO-S1
arm SILO-S1
disarm SILO-S1
launch SILO-S1 500 -250
clear
quit
```

## Automatic GitHub updates

Both programs check their matching `version.txt` on GitHub at startup. The updater appends cache-busting query parameters to raw GitHub requests. If a newer semantic version is available, it downloads the replacement script, keeps a `.bak` copy, installs the update, and reboots the OpenComputers machine.

Automatic GitHub checks require an OpenComputers **Internet Card** and internet access enabled in the OpenComputers configuration. If GitHub cannot be reached, the installed version continues normally.

Updates are startup-only so a field node will not reboot itself unexpectedly while running.

## HBM integration

The field-node implementation expects:

- an HBM component exposed as `ntm_launch_pad`
- an OpenComputers modem
- an Inventory Controller Upgrade for exact loaded-missile detection
- an OpenComputers Internet Card only if that node should self-update directly from GitHub
