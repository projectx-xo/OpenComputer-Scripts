# STRATCOM 3.3

Command software for Minecraft OpenComputers and HBM Nuclear Tech. CENTRAL manages strike, defense, radar and combined-intelligence nodes over the existing wireless mesh.

Version 3 runs as an OpenOS boot service. The console attaches to that service; closing it leaves the network and runtime operating. Installed software starts from disk before update checks. Application updates restart the application, without rebooting the computer.

## Install this preview

Run these in the **OpenOS shell**, one line at a time. These are script invocations, not lines for the interactive `lua>` prompt.

On CENTRAL:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/22c830ae4cc2fcb10f83d08dd9a0e197838d5bde/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua central -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/22c830ae4cc2fcb10f83d08dd9a0e197838d5bde/release.lua"
lua /usr/bin/stratcom.lua
```

On a field node, replace the role and ID as appropriate:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/22c830ae4cc2fcb10f83d08dd9a0e197838d5bde/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua node strike SILO-S1 -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/22c830ae4cc2fcb10f83d08dd9a0e197838d5bde/release.lua"
lua /usr/bin/stratcom.lua
```

| Role | Example ID | Connected hardware |
| --- | --- | --- |
| `strike` | `SILO-S1` | One or more `ntm_launch_pad` or `ntm_custom_launch_pad` components and inventory controllers |
| `defense` | `ABM-A1` | One launch pad and inventory controller |
| `radar` | `RADAR-1` | One or more `ntm_radar` components |
| `intel` | `INTEL-1` | `ntm_satlink` connected to a `COMBINED_INTEL` satellite |

Every machine needs OpenOS with its thread library and a modem. Internet is needed for online installation and automatic application-bundle downloads. Field-node runtime deployment still travels over the mesh from CENTRAL.

The installer enables `rc stratcom enable`, saves the machine configuration, installs the runtime and starts the service. It does not replace an existing node's ID, role, hardware mappings or installed runtime. A conflicting role/ID is rejected.

If OpenOS reports `stratcom: is a directory`, use `lua /usr/bin/stratcom.lua` to attach, or append commands such as `service status` or `doctor`. This avoids the `/home/stratcom` directory shadowing the executable. Attach only after the installer reports success.

### Offline field nodes

Copy the complete extracted release directory to a disk accessible to the node. From that directory, run:

```sh
lua install.lua node radar RADAR-1 -- --bundle .
lua /usr/bin/stratcom.lua
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

### Large Launch Pads

HBM's **Large Launch Pad** (the custom missile launch table) exposes `ntm_custom_launch_pad`. It needs [mod v1.7](https://github.com/projectx-xo/HBM-s-Nuclear-Tech/releases/tag/tjHBM-NTM-v1.7) or later to fix its OpenComputers component registration. Connect the adapter or OC cable directly to the **center core block**, preferably underneath; the outer platform and port dummy blocks do not expose the OC interface. Check `components ntm_custom_launch_pad` in the OpenOS shell.

STRATCOM strike runtime **3.1.0** recognizes both pad types. Custom pads use their own contents/readiness callbacks and set the loaded designator's coordinates before launching. Keep a compatible designator in the pad. Map each pad to the correct inventory controller and side with `hardware <node>` and `map` as below. The defense runtime remains for ordinary ABM pads.

### Paced strikes and counterstrikes

CENTRAL 3.3 with strike runtime 3.1 supports an optional interval in seconds:

```text
strike SILO-S2 nuclear 4 507 1709 3
confirm STRIKE
```

This queues four ready launchers at the same target, with at least three seconds between launches. The default is one second; allowed intervals are 1–60 seconds. Launch spacing does not guarantee identical impact spacing when missile speeds or flight paths differ. The console acknowledges the queue immediately. Use `status SILO-S2` for remaining launches and `logs` for progress/results. Commands remain responsive, and delayed ticks never fire missed shots in a burst. `disarm SILO-S2 all`, stopping the node, or entering maintenance cancels remaining shots. A failed launch or changed payload also cancels the remainder. Queues are not resumed after a runtime restart.

If a hostile track has an associated possible launch site and is lost after a successful ABM launch, CENTRAL records a counterstrike suggestion in `logs` and `defense status`. Track loss remains **intercept unconfirmed**; the origin is an estimate. No strike is launched automatically.

```text
counterstrike nuclear 1
confirm STRIKE
```

Here `1` is the number of missiles. The short command uses the latest suggestion and selects an available strike node with enough ready payloads of that class. Review the printed site, coordinates, selected launchers and interval before confirming. Without a suggestion, specify a recorded site from `launchsites`. For example, site #7, four launches from SILO-S2, three seconds apart:

```text
counterstrike nuclear 4 7 SILO-S2 3
confirm STRIKE
```

The full syntax is `counterstrike <class> <count> [site-id] [node] [interval-seconds]`. `launchsite <id>` shows the origin estimate and confidence. Payload classes still come from the saved catalog; use `payloads <node>` and `classify <item-id> <class>` for unclassified missiles. The latest suggestion lasts for the CENTRAL session; recorded site IDs remain saved across restarts.

### Stale ABM status

`ABM_STATUS_STALE` means CENTRAL has no recent readiness response, even if bootstrap heartbeats show the node online. CENTRAL 3.3 keeps each background status request valid for up to 15 seconds, fixing rejection of replies delayed beyond the five-second polling interval. `defense status` refreshes stale readiness and displays its age and any reported status error. If it still times out, check `status ABM-A1`, `doctor ABM-A1`, the node's local `doctor`, chunk loading, and the modem link; stale readiness never enables a launch.

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

## Command-room hologram

Connect an OpenComputers hologram projector to **CENTRAL's component network**. The `intel` node keeps its satellite relay; CENTRAL fetches the completed scan over the modem. No satellite relay is required at CENTRAL.

Holograms require CENTRAL **3.2.0 or newer** and intelligence runtime **1.2.0**. Follow [Updates and recovery](#updates-and-recovery) to install the current bundle. Check `nodes` for INTEL-1 version 1.2.0 before scanning; `deploy INTEL-1` requests deployment if needed.

In CENTRAL's STRATCOM console:

```text
scan INTEL-1 507 1709
scan INTEL-1 status
hologram status
```

After `COMPLETE`, CENTRAL fetches and draws the model automatically. A scan started locally at the intel node also updates the command-room projector. Status reports `FETCHING`, `DRAWING`, or `DISPLAYED`, with the source node, scan summary and world blocks per voxel. The last completed display stays visible while another scan runs or downloads. With several intel nodes, a newly received completed scan selects the displayed source.

Scans with no structural samples or findings clear the previous geometry and report `EMPTY`.

Once the model reports `DISPLAYED`, list its findings and select a number from that list:

```text
hologram list
hologram select 2
hologram select all
hologram view findings
hologram view structure
hologram view cutaway
```

Finding numbers match `scan INTEL-1 results` for that scan. The list and selection status show classification, exact bounds, confidence and target count. Selection draws that finding in red and other findings in amber. Tier 1 projectors show only the selected finding, since they cannot separate colors. `select all` restores all findings. Selection and view changes redraw the cached model without fetching it again; wait for `DISPLAYED` before the next change.

The default **cutaway** opens the projector-local +Z half of inferred enclosures and their nearby sampled walls; other structural samples use the scene's middle Z plane. Inferred bounds remain as outlines. `view structure` restores every sampled block, while `view findings` removes structural samples entirely. Views preserve the same coordinate transform and scale.

```text
hologram show INTEL-1
hologram clear
hologram bind <full-projector-address>
```

`show` selects or retries that node's latest announced completed scan. `clear` leaves the projector blank until a new scan arrives or you use `show`. A single projector is selected automatically. With several projectors, use `components hologram` in the OpenOS shell to list addresses, then `hologram bind` in STRATCOM; the binding is saved in CENTRAL's preferences. Missing projectors pause display work without blocking scan commands.

The [OpenComputers hologram API](https://ocdoc.cil.li/component:hologram) supports **48 × 32 × 48 voxels**. Tier 2 adds three colors; Tier 1 uses one color:

| Appearance on Tier 2 | Meaning |
| --- | --- |
| Dim cyan points | Sampled structural context |
| Amber outlines | Inferred structures, including possible silos; other findings when one is selected |
| Red symbols | Equipment findings, or the selected finding |

Missiles use a vertical marker, launch infrastructure a larger horizontal ring, and silo hatches a smaller ring with a center point. Other point findings use a cross. Non-point findings also show their reported bounding box. A loaded missile and its launch table can share one reported coordinate; their different symbols keep both visible and independently selectable. These symbols indicate type, not physical missile or launcher dimensions.

The model is centered and reduced uniformly when necessary, preserving proportions. Small models retain one world block per voxel. X, Y and Z map to the projector's local axes; physical projector orientation determines how that relates to the room. Existing projector scale/rotation settings are preserved.

This is the satellite's **sampled structure and finding bounds**, not a block-perfect world copy. Unsampled terrain and blocks are not invented. The console remains the source for exact coordinates, confidence, target IDs and resistance values. The renderer supports the HBM limits of 8,192 structural samples and 128 findings, loads small pages, and writes at most 64 voxels per drawing step. Scan/session/request identities reject stale pages; missing replies get bounded retries and an explicit timeout. Older intel runtimes retain their coordinate-only display with an explicit upgrade notice; typed selection requires runtime 1.2.0.

## Updates and recovery

To update an existing 3.1.4 or 3.2 installation to **3.3.0**, enter `quit` in CENTRAL's console, then run these lines in the OpenOS shell:

```sh
echo "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/22c830ae4cc2fcb10f83d08dd9a0e197838d5bde/release.lua" > /home/stratcom/source.txt
lua /usr/bin/stratcom.lua update check
lua /usr/bin/stratcom.lua
```

Use `service status` until it reports `running 3.3.0`. CENTRAL distributes strike runtime 3.1.0 to online strike nodes. Check `nodes`; if a deployment is held, use `deploy SILO-S1` or `deploy SILO-S2` and wait until their runtime version is 3.1.0. Field-node reinstalls are unnecessary for this update. The ABM polling fix runs on CENTRAL; the defense runtime remains 2.1.0. Large Launch Pad discovery additionally needs the mod v1.7 JAR on the server and clients.

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

The default source used when `--source` is omitted is `main`. These preview instructions pin the reviewed `3.3.0` manifest and its immutable source commit. To follow future releases on this preview branch, set `/home/stratcom/source.txt` to `https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua`. Use the main `release.lua` URL after the release is merged there.

## Development and verification

Run all tests from the repository root:

```sh
lua tests/bootstrap_test.lua
lua tests/central_test.lua
lua tests/central_integration_test.lua
lua tests/command_test.lua
lua tests/hologram_test.lua
lua tests/hologram_integration_test.lua
lua tests/runtime_test.lua
lua tests/strike_integration_test.lua
lua tests/service_test.lua
```

The suites execute production code with simulated OpenOS hardware, filesystem, network and scheduling boundaries. An optional [GitHub Actions workflow](docs/ci/lua-checks.yml) runs Lua 5.2 and 5.3. Copy it to `.github/workflows/lua-checks.yml` using an account/token with workflow permission. They cover offline startup, command correlation, stop persistence, deployment/update failures, rollback, inventory mappings, stale telemetry and combined-only scans. See [TESTING.md](TESTING.md) for the in-game smoke procedure and the limits of these tests.

To publish another bundle, commit its application files and version metadata first, then generate the manifest from that exact commit:

```sh
python3 tools/make_release.py --ref <full-source-commit> --version 3.3.0
```

Use a new version for every changed bundle. Commit `release.lua` separately so it can reference the immutable preceding source commit. A checksum validates transfer integrity; it is not a signature. Installers and update channels must come from the repository you trust.
