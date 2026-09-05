# STRATCOM 3.0

Command software for Minecraft OpenComputers and HBM Nuclear Tech. CENTRAL manages strike, defense, radar and combined-intelligence nodes over the existing wireless mesh.

Version 3 runs as an OpenOS boot service. The console attaches to that service; closing it leaves the network and runtime operating. Installed software starts from disk before update checks. Application updates restart the application, without rebooting the computer.

## Install this preview

Run these in the **OpenOS shell**, one line at a time. These are script invocations, not lines for the interactive `lua>` prompt.

On CENTRAL:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua central --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
stratcom
```

On a field node, replace the role and ID as appropriate:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua node strike SILO-S1 --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
stratcom
```

| Role | Example ID | Connected hardware |
| --- | --- | --- |
| `strike` | `SILO-S1` | One or more `ntm_launch_pad` components and inventory controllers |
| `defense` | `ABM-A1` | One launch pad and inventory controller |
| `radar` | `RADAR-1` | One or more `ntm_radar` components |
| `intel` | `INTEL-1` | `ntm_satlink` connected to a `COMBINED_INTEL` satellite |

Every machine needs OpenOS with its thread library and a modem. Internet is needed for online installation and automatic application-bundle downloads. Field-node runtime deployment still travels over the mesh from CENTRAL.

The installer enables `rc stratcom enable`, saves the machine configuration, installs the runtime and starts the service. It does not replace an existing node's ID, role, hardware mappings or installed runtime. A conflicting role/ID is rejected.

### Offline field nodes

Copy the complete extracted release directory to a disk accessible to the node. From that directory, run:

```sh
lua install.lua node radar RADAR-1 --bundle .
stratcom
```

The directory must contain `release.lua` and the matching source files. The installer validates the local files and makes no Internet requests. Fresh offline installs disable automatic Internet update checks; CENTRAL still deploys role runtimes through the modem. Copy a newer bundle and repeat the install to update the node's bootstrap/service helpers.

### Migrating an existing installation

1. Stop the old foreground program when the machine is idle: `quit` on CENTRAL, or Ctrl+C on the old bootstrap.
2. Run the installer above once on each machine, using its existing node role and ID. Update field-node bootstraps before using the new management commands from CENTRAL.
3. Use `stratcom` from now on. The old `/home/stratcom/central.lua` and `bootstrap.lua` are no longer the service entry points.
4. Check `stratcom doctor`, then on CENTRAL run `nodes`, `doctor SILO-S1` and `status SILO-S1`.
5. For strike nodes with several pads/controllers, inspect and save the hardware assignments below.

To reinstall stable service helpers later, first run `stratcom service stop`, check `stratcom service status` until it reports stopped, then rerun the installer. Application bundle updates do not rewrite the live supervisor. Existing payload classifications and launch-site records stay at their existing paths. The legacy `node/` v1 software is retained for reference only.

## Daily use

```sh
stratcom
stratcom service status
stratcom logs 30
stratcom doctor
```

Inside the console, `quit`, EOF and Ctrl+C detach. `service stop` explicitly stops the application; `service start` starts it again. `service restart` restarts the application without rebooting OpenOS. A service stop lasts until a manual start or the next computer boot; `rc stratcom disable` disables boot startup.

Node runtime intent is separate: `stop SILO-S1` and `maintenance SILO-S1 on` on CENTRAL persist across computer restarts. `start SILO-S1` and `maintenance SILO-S1 off` resume operation. CENTRAL's saved explicit preference is authoritative when it manages that node. Local node consoles also support `start`, `stop` and `maintenance`.

Background messages go to a bounded log. They do not overwrite the console prompt. Use `logs` to read recent events. `status` waits for a response and reports a timeout when fresh data is unavailable. Commands and confirmations are never replayed after a restart.

### CENTRAL commands

```text
help
discover
nodes
info SILO-S1
status SILO-S1
payloads SILO-S1
doctor SILO-S1
alias SILO-S1 ALPHA
status ALPHA
start SILO-S1
stop SILO-S1
restart SILO-S1
maintenance SILO-S1 on
maintenance SILO-S1 off
deploy SILO-S1
deploy all
sync
radars
radar RADAR-1
tracks
launchsites
launchsite 1
defense node ABM-A1
defense protect 508 1710 150
defense auto on
defense status
engagements
```

`sync` reloads the installed bundle's runtime manifest. `update check` obtains a newer application bundle from GitHub. Deployment is serialized and deferred while relevant operations are busy. A failed runtime version is held until an explicit `deploy` retry or a newer version arrives.

Launcher and payload commands remain available:

```text
arm SILO-S1 1
disarm SILO-S1 all
launch SILO-S1 1 508 1710
confirm LAUNCH
strike SILO-S1 conventional 2 508 1710
confirm STRIKE
cancel
classify hbm:item.missile_drill bunker
```

The service prints a plan before a launch/strike confirmation. Confirmations expire after 30 seconds. The selected launchers and payloads are checked again before sending. Single-pad defense nodes use `arm ABM-A1` and `launch ABM-A1 508 1710`.

### Stable hardware assignments

```text
hardware SILO-S1
map SILO-S1 BRAVO <pad-address> <inventory-controller-address> 2 3
payloads SILO-S1
```

The last arguments are the inventory side (`0`–`5`) and optional slot. Use the full component addresses listed by `hardware`. With one pad and one controller, the strike runtime can save the unambiguous pair automatically. With several devices, it leaves inventories unmapped until assigned. A missing device never causes another device to take over its saved launcher number.

Mappings are saved in `/home/stratcom/config.lua`. A local strike-node console accepts `hardware` and `map BRAVO <pad-address> <inventory-controller-address> 2 3`. Disarm before changing mappings. Missile slots are cached; empty/changed slots trigger a rescan, and launch actions recheck readiness.

## Satellite scans

From the console on the computer connected to the satellite link:

```text
scan 508 1710
scan status
scan results
scan results 2
scan structure
scan structure 2
```

From CENTRAL, address the intelligence node:

```text
scan INTEL-1 508 1710
scan INTEL-1 status
scan INTEL-1 results 1
scan INTEL-1 structure 1
```

Wait for `COMPLETE` before reading results. Findings show classifications, coordinates, confidence, target type, target ID and target count, including the missile/silo fields supplied by your HBM fork. Structural pages show **HBM blast resistance** and use eight cells per console page. Finding pages contain six findings.

These commands require `COMBINED_INTEL`. A communications relay satellite or another intelligence satellite type is rejected. The relay must be connected and tuned to the right frequency. If several `ntm_satlink` components are attached, set `satelliteAddress` in the node configuration to select one.

## Updates and recovery

```text
update status
update check
update apply
update rollback
logs
```

Online installs check after startup and then hourly. Downloads use one immutable source commit, with syntax, size and checksum validation. The current application runs while downloading. Installation waits until idle. A candidate has startup checks and a 15-second probation period; detected startup failures restore the previous bundle. Repeated application failures back off and stop retrying after five attempts until `service start`.

Node runtime transfers keep the current runtime active until a complete candidate is ready. Failed startup, failed first tick, write errors, interrupted activation and duplicate commit messages have explicit recovery paths. Completed deployment replies are retained in memory for ten minutes; CENTRAL can reconcile versions again after a bootstrap restart.

Configuration and saved operator preferences live outside release bundles. On disk:

- `/home/stratcom/service-config.lua`: service kind and `autoUpdate` setting.
- `/home/stratcom/source.txt`: update-channel manifest URL.
- `/home/stratcom/config.lua`: node identity and hardware assignments.
- `/home/stratcom/preferences.db`: CENTRAL's node preferences and defense configuration.
- `/home/stratcom/runtime/`: node current/previous runtime, versions and recovery files.
- `/home/stratcom/releases/`: validated application bundles.

The default source used when `--source` is omitted is `main`. These preview instructions explicitly select the review branch. After this release merges, change `source.txt` to the main `release.lua` URL if you want future main-branch releases.

## Development and verification

Run all tests from the repository root:

```sh
lua tests/bootstrap_test.lua
lua tests/central_test.lua
lua tests/central_integration_test.lua
lua tests/command_test.lua
lua tests/runtime_test.lua
lua tests/service_test.lua
```

The suites execute production code with simulated OpenOS hardware, filesystem, network and scheduling boundaries. An optional [GitHub Actions workflow](docs/ci/lua-checks.yml) runs Lua 5.2 and 5.3. Copy it to `.github/workflows/lua-checks.yml` using an account/token with workflow permission. They cover offline startup, command correlation, stop persistence, deployment/update failures, rollback, inventory mappings, stale telemetry and combined-only scans. See [TESTING.md](TESTING.md) for the in-game smoke procedure and the limits of these tests.

To publish another bundle, commit its application files and version metadata first, then generate the manifest from that exact commit:

```sh
python3 tools/make_release.py --ref <full-source-commit> --version 3.0.0
```

Use a new version for every changed bundle. Commit `release.lua` separately so it can reference the immutable preceding source commit. A checksum validates transfer integrity; it is not a signature. Installers and update channels must come from the repository you trust.
