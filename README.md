# OpenComputer Scripts

OpenComputers scripts for an HBM Nuclear Tech command-and-control network.

## Layout

- `node/node.lua` — reusable field-node daemon for launch-pad sites such as `ABM-A1`
- `node/config.example.lua` — example persistent site configuration
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

Nodes broadcast `HELLO` on startup and `HEARTBEAT` every 5 seconds. Central automatically requests a full `STATUS` packet when it discovers a new node.

## Field node install

Create the persistent site config first:

```sh
mkdir /home/stratcom
edit /home/stratcom/config.lua
```

Example for the first ABM site:

```lua
return {
    id = "ABM-A1",
    role = "defense",
    port = 4510,
}
```

Then install the reusable node program:

```sh
wget -f https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/node/node.lua /home/stratcom/node.lua
lua /home/stratcom/node.lua
```

The config file is never replaced by software updates, so the same `node.lua` can be deployed to every site.

## Central install

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

## Automatic GitHub updates

Both `node.lua` and `central.lua` check their matching `version.txt` on GitHub at startup. If a newer semantic version is available, the program downloads the replacement script, keeps a `.bak` copy of the previous script, installs the update, and reboots the OpenComputers machine.

Automatic GitHub checks require an OpenComputers **Internet Card** and internet access enabled in the OpenComputers configuration. If GitHub cannot be reached, the installed version continues normally.

Updates are startup-only so a field node will not reboot itself unexpectedly while running.

## HBM integration

The current field-node implementation expects:

- an HBM component exposed as `ntm_launch_pad`
- an OpenComputers modem
- an OpenComputers Internet Card only if that node should self-update directly from GitHub
