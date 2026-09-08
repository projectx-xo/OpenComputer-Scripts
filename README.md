# STRATCOM 3.15.0

**Update the fleet from CENTRAL with `upgrade`; inspect progress with `upgrade status`.** For the first transition from an older release, run `update check` on CENTRAL. [Update guide](docs/easy-updates.md).

BaseCenter team integration was removed in 3.14.0. STRATCOM authentication keys, SATCOM and launch IFF remain independent and supported.

For nuclear monitoring and post-blast intelligence scans, see [STRATCOM 3.8.0](docs/release-3.8.0.md).

Command software for Minecraft OpenComputers and HBM Nuclear Tech. CENTRAL manages strike, defense, radar and combined-intelligence nodes over the existing wireless mesh.

For the current full upgrade procedure and automatic enrollment, see [STRATCOM 3.6.0](docs/release-3.6.0.md).

Version 3 runs as an OpenOS boot service. The console attaches to that service; closing it leaves the network and runtime operating. Installed software starts from disk before update checks. Application updates restart the application, without rebooting the computer.

## Status dashboard

Opening `stratcom` on a field node shows a coloured ASCII status page: identity, team, CENTRAL contact, equipment readiness, updates and recent events. CENTRAL opens the same dashboard style with fleet, network authentication and automatic-defense status. Press **C** for the console, **Q** to detach, or **Up/Down** to scroll. Enter `dashboard` in a console to return, or use `stratcom console` from OpenOS to open command input directly. One-shot commands remain supported. Detaching either view leaves the service running.

Update from CENTRAL with `upgrade`. Once nodes finish updating, quit any already-open console and reopen `stratcom` (or `lua /usr/bin/stratcom.lua`). The update migrates known shipped console launchers automatically and backs them up in `/home/stratcom/console-backups/`; custom launchers are retained. Future dashboard changes travel in the normal application bundle. The page opens when you launch `stratcom`, not automatically at OpenOS boot. See [3.13.0 release notes](docs/release-3.13.0.md).

## Install this preview

For a multiplayer team network, create one trusted key file outside Minecraft and copy it to removable OpenComputers media:

```text
STRATCOM-KEY-1
network=BLUE
key=<64 random hexadecimal characters>
```

Use 32 bytes from a cryptographically secure random source for `key`. Install each field machine locally with that medium; field nodes retain only a key derived for their physical computer address. CENTRAL retains the team root key.

```sh
lua /tmp/stratcom-install.lua central --network BLUE --key-file /mnt/team/stratcom.key -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
lua /tmp/stratcom-install.lua node --network BLUE --key-file /mnt/team/stratcom.key -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
```

Provision field nodes first during downtime and CENTRAL last, then remove the key medium. A secured installation rejects legacy and wrong-team traffic without falling back. Installations without a key continue in protocol-v2 compatibility mode and display `INSECURE LEGACY NETWORK`.

For a new field node, connect its hardware and either a modem or a Satellite Ground Station tuned to the Communications Satellite. The automatic installer lets CENTRAL select its role and name:

```sh
lua /tmp/stratcom-install.lua node -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
```

One ordinary launch pad containing an Anti Ballistic Missile becomes `ABM-A#`; a pad containing another missile or a multi-pad/custom-pad group becomes `SILO-S#`; radar hardware becomes `RADAR-##`; and a ground station tuned to a combined intelligence satellite becomes `SAT-#`. Empty single launch pads and machines with conflicting hardware wait for correction instead of being assigned. Existing explicit `node <role> <id>` installs remain supported.

Run these in the **OpenOS shell**, one line at a time. These are script invocations, not lines for the interactive `lua>` prompt.

On CENTRAL:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua central -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
lua /usr/bin/stratcom.lua
```

On a field node, replace the role and ID as appropriate:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/install.lua" /tmp/stratcom-install.lua
lua /tmp/stratcom-install.lua node strike SILO-S1 -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
lua /usr/bin/stratcom.lua
```

| Role | Example ID | Connected hardware |
| --- | --- | --- |
| `strike` | `SILO-S1` | One or more `ntm_launch_pad` or `ntm_custom_launch_pad` components and inventory controllers |
| `defense` | `ABM-A1` | One launch pad and inventory controller |
| `radar` | `RADAR-1` | One or more `ntm_radar` components |
| `intel` | `INTEL-1` | `ntm_satlink` connected to a `COMBINED_INTEL` satellite |

Every machine needs OpenOS with its thread library and at least one transport: a modem or an `ntm_satlink` ground station. Internet is needed for online installation and automatic application-bundle downloads. Field-node runtime deployment travels over the available STRATCOM transport.

After installation, STRATCOM can use a modem, the Communications Satellite, or both. Satellite transport requires an `ntm_satlink` ground station at CENTRAL and at each remote node, all tuned to the same Communications Satellite frequency. When both transports deliver the same packet, its envelope ID ensures it is processed once. The satellite carries communications only; it does not transport ME items or propellant.

A SAT node (the existing `intel` runtime role) automatically selects its Combined Intelligence Satellite ground station for scanning by satellite type. CENTRAL and node dashboards display this role as SAT. New automatic enrollments receive `SAT-#` IDs; existing `INTEL-#` IDs remain valid. If it communicates with CENTRAL over SATCOM, give it a second ground station tuned to the Communications Satellite; otherwise use a modem for transport.

Secured networks authenticate every complete serialized packet with HMAC-SHA-256 before parsing it. Boot epochs and sequence windows reject captured traffic from old sessions and duplicate modem/SATCOM delivery. Network traffic remains visible to receivers and can still be jammed; the security boundary prevents other teams from forging accepted commands or telemetry.

The system roles and authority boundaries are summarized in [Distributed STRATCOM architecture](docs/network-architecture.md).

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

If a node is online but CENTRAL cannot read its status, run `status` on the field node's own console to exercise its runtime locally. Bare `doctor` reports service and component information instead. CENTRAL reports a correlated runtime error as `STATUS FAILED` with the node's error text; `TIMEOUT` means no matching status result arrived before the deadline.

CENTRAL repeats the control-claim handshake when a field node announces a new runtime session. Older CENTRAL builds can retain a stale claim after a node reboot or reinstall: discovery works but operational commands are ignored. Restarting CENTRAL's service clears that stale in-memory claim; then use `discover` and `status <node>` to reconnect.

## Daily use

```sh
stratcom
stratcom service status
stratcom logs 30
stratcom doctor
```

Inside the console, `quit`, EOF and Ctrl+C detach. `service stop` explicitly stops the application; `service start` starts it again. `service restart` restarts the application without rebooting OpenOS. A service stop lasts until a manual start or the next computer boot; `rc stratcom disable` disables boot startup.

Node runtime intent is separate: `stop SILO-S1` and `maintenance SILO-S1 on` on CENTRAL persist across computer restarts. `start SILO-S1` and `maintenance SILO-S1 off` resume operation. CENTRAL's saved explicit preference is authoritative when it manages that node. Local node consoles also support `start`, `stop` and `maintenance`.

Routine background messages go to a bounded log. Operational radar acquisitions, possible launch sites and automatic-defense engagement updates also appear immediately as `[ALERT]` messages with a short tone while the console is attached. Alerts preserve the current input and cursor position and remain visible while a command waits for a reply. Reattaching shows the retained alert history with timestamps; `logs` provides recent event details. The service retains 50 alerts independently of the 200-line general log; it reports when older alerts have expired. A radar acquisition means a contact was detected, not that its exact launch time or origin is known.

The live-alert fix changes `central/central.lua`, `service/stratcom.lua` and `service/console.lua`. Update CENTRAL's stable service helpers using the installer with the service stopped, as well as installing the patched application bundle; application-only updates do not replace those helpers. Radar and defense node runtimes do not need replacement for this notification fix. `status` waits for a response and reports a timeout when fresh data is unavailable. Commands and confirmations are never replayed after a restart.

### Silo supplies

The workspace logistics extension loads named missile designs from ME storage, fuels a requested number of launchers from local propellant tanks, and reclaims unused fuel. See [Silo group logistics](docs/silo-logistics.md) for hardware, setup commands and deployment requirements. Preparation remains separate from arming and launching.

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

### Radar-to-ABM entity handoff (3.5.0)

When radar identifies a launch site, CENTRAL queues an intelligence verification scan using an online, claimed, idle `intel` node with a Combined Intelligence Satellite. `launchsite <id>` shows verification status. A verified pad, launch table, compact launcher or silo hatch within 100 blocks replaces the estimate with exact X/Y/Z coordinates; a loaded or stored missile is the fallback. Infrastructure is preferred, then the nearest finding. Findings must be point locations with at least 80% confidence. Flying missiles, assembly machines and broad structure bounds do not qualify.

The original radar estimate is retained, and subsequent launches do not average away verified coordinates. Counterstrike preparation uses the refined location and still requires launch confirmation. Verification never launches a missile. Only one automatic scan runs at a time; busy or unavailable nodes are skipped. The queue is limited to 32 sites and waits up to five minutes for an available node. Scans time out after three minutes; inconclusive attempts keep the estimate and can be retried on a later launch after five minutes. Unloaded areas retain the satellite's existing coverage limits; this does not load chunks.

This feature requires the updated CENTRAL bundle (including `central/site_intel.lua`) and updated `runtime/intel.lua` on intelligence nodes. Older runtimes lack the scan-request correlation and verification pages, so they cannot refine sites. No mod JAR change is required. These workspace changes must be included in a release before the normal updater can install them.

With the matching HBM entity-handoff patch installed on the server and clients, deploy radar runtime 1.2.0 and defense runtime 2.3.0 from CENTRAL 3.5.0. `sync`, `deploy RADAR-01` and `deploy ABM-A1` update those example nodes. Existing 3.4.1 notification helpers do not need another reinstall.

The radar reports the selected contact's entity ID, UUID and dimension with its observation. CENTRAL preserves that identity through tracking and arming; the ABM pad resolves and validates the same living missile before launching with its target already assigned. Missing, dead, changed or other-dimension targets fail without a coordinate fallback. No additional chunks are loaded to resolve a target. Flight and subsequent reacquisition follow HBM's native radar-linked ABM behavior.

`defense status` reports entity-handoff capability. For identity-bearing contacts on a capable pad, the 1,000-block seeker-search gate is bypassed, just as with native radar target assignment. Hostile/inbound confirmation, readiness, IFF and stale-observation checks still apply. Old radars or pads continue using the coordinate fallback below. Radar visibility and a launch acknowledgement never prove an interception.

### ABM acquisition range

With the updated mod and defense runtime, a tracked ABM launch returns the interceptor's UUID. CENTRAL polls that exact interceptor and target once per second. Three matching reports over at least two seconds that the interceptor has ended while the exact target is still alive, plus fresh radar observations after the first report, confirm `MISS`. The target then qualifies again through normal inbound, IFF, auto-defense, range and readiness checks. A replenished ABM pad can fire another interceptor; this does not create ammunition or bypass fueling requirements.

Living interceptors remain under observation beyond the old 20-second window. Thirty seconds without usable outcome telemetry reports `UNCONFIRMED`; older launches without interceptor identity retain the 20-second observation window. Neither case permits a speculative automatic retry for that track. Contact loss also remains unconfirmed. Restarting/unloading the pad or losing the target makes outcome evidence unavailable, not proof of a miss. The mod retains only the most recent tracked interceptor per pad in memory; it does not replay launches after restart. Install the updated mod JAR, CENTRAL and defense runtime together for confirmed re-engagement.

CENTRAL 3.4.2 ships defense runtime 2.2.1, which calls `getPos` directly by component address. This handles cached proxies that omit the method despite the pad accepting it. Update CENTRAL, then `sync` and `deploy ABM-A1`; no mod update or helper reinstall is needed when upgrading from a complete 3.4.1 installation.

Automatic defense holds fire until the observed target is strictly less than 1,000 blocks from the ABM launch pad in 3D, including altitude. CENTRAL checks before arming and again on the ARM reply; an invalidated engagement is disarmed. Missing pad coordinates or stale target/readiness data hold fire. `defense status` shows the range policy and warns when pad position is unavailable. Range holds appear in operational alerts. This is a launch-distance check, not a guarantee of seeker lock after the missile's activation delay; HBM also excludes Stealth Missiles from ABM acquisition.

This change requires the patched CENTRAL application and defense `runtime/launchpad.lua`, which now reports the pad's `getPos()` coordinates. An older runtime or pad without that callback cannot qualify automatic fire. The live-alert changes additionally require reinstalling CENTRAL's stable service helpers. Included in CENTRAL 3.4.1 with defense runtime 2.2.0.

A possible launch site is recorded only when a missile is first observed at Y ≤ 160 and subsequently climbs at least 35 blocks and departs at least 40 blocks horizontally, with two qualifying ascending observations. Radar visibility at a higher altitude does not establish an origin. Use `launchsites` for recorded estimates and `logs` / `engagements` for recent activity.

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

The last arguments are the inventory side (`0`–`5`) and optional slot. Use the full component addresses listed by `hardware`. With one pad and one controller, the strike runtime can save the unambiguous pair automatically. With mod 1.13 and strike runtime 3.3.0, missing mappings for several devices are discovered from physical adapter adjacency and saved automatically. Identical missile contents do not affect matching. Ambiguous connections, unsupported controller hosts, and older mod callbacks remain unmapped until assigned. Discovery is limited to 64 pad/controller probes per refresh; larger groups require manual mappings. Existing saved mappings are preserved. A missing device never causes another device to take over its saved launcher number.

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

These commands require `COMBINED_INTEL`. A communications relay satellite or another intelligence satellite type is rejected. The relay must be connected and tuned to the right frequency. A Communications Satellite ground station can be attached alongside the Combined Intelligence station without manual selection. If more than one Combined Intelligence station is attached, set `satelliteAddress` in the node configuration to select one. An explicit selection is always respected.

## Command-room hologram

### Native HBM projection table (3.4.0)

Install mod **tjHBM-NTM-v1.10** on the server and clients, update CENTRAL to **3.4.0**, and check that `INTEL-1` runs intelligence runtime **1.3.0** (`deploy INTEL-1` if needed). Version 1.10 displays a full-color miniature with Minecraft block textures; run a fresh scan after updating. Place an **Intelligence Projection Table** in the command room and put an OpenComputers adapter against its block, wired to CENTRAL. Leave room above it for a projection up to six blocks across/high by default. The satellite ground station stays at INTEL-1.

The table is in HBM's missile creative tab and has an assembly-machine recipe. Its OC component is `ntm_intel_projector`. If CENTRAL has no saved projector binding, one native table is preferred automatically. If you previously bound an OC hologram, run `components ntm_intel_projector` in the OpenOS shell, then `hologram bind <full-address>` in STRATCOM.

Run a **new combined scan**; older snapshots lack the block types and metadata needed for textures:

```text
scan INTEL-1 507 1709
scan INTEL-1 status
hologram status
```

The completed scan appears automatically. The table captures every Y level in the 64 × 64 footprint, using normal block textures and colors, opaque walls and transparent glass. Exterior mode shows the complete captured structure; terrain is hidden initially. Right-click the table for view, floor, cut-plane, rotation, size, terrain and finding controls, or use CENTRAL:

```text
hologram view exterior
hologram view interior
hologram floor 30
hologram view cutaway
hologram cut z:1709
hologram cut x:508
hologram cut none
hologram terrain on
hologram terrain off
hologram rotate 90
hologram scale 8
hologram list
hologram select 2
hologram select all
```

`interior` initially removes the highest layer. `floor 30` shows Y ≤ 30; `floor all` restores all heights. A cut retains X or Z ≤ its world-coordinate value. `cutaway` initially opens the +Z side through the captured structure's center. Rotation is in degrees (−360..360); size is the longest projection dimension in Minecraft blocks (2..12). Clipping and finding selection preserve the coordinate transform. Terrain visibility changes the fitted extent.

Finding numbers match `scan INTEL-1 results`: coral arrows mark missiles, amber diamonds mark launchers/equipment, violet diamonds mark hatches, and white marks the selected finding. Co-located missile and launcher symbols remain at the same scan coordinate with separate labels. Unselected inferred regions are hidden to reduce clutter; select their finding number to locate them. Markers remain visible through the projection and across cuts so a hidden object is still locatable.

The model preserves captured **block types, textures and metadata**, including colored HBM concrete and native vanilla stair/slab shapes. Custom machine renderers use their block textures on captured bounds; animated tile/entity meshes such as the loaded missile remain finding markers. Biome-specific tint is not captured. Natural terrain classification is a filter; turn it on when inspecting a stone/earth structure. With HBM v1.18, scans temporarily load their 64 × 64 target footprint (up to 25 chunks), one chunk per tick, then release the ticket after capture or failure. A player need not be at the target. Older mod versions only scan loaded chunks. The capture adds about 13 seconds at 20 TPS. Snapshots transfer in 64 KiB pieces and are rendered from cached block geometry; a 65,536-visible-block limit displays a notice to use a tighter cut.

The table retains its displayed snapshot across reloads. `hologram show INTEL-1` reloads that node's latest announced result; `hologram clear` clears it. An obsolete snapshot reference is rejected instead of silently displaying different data. The scan's source dimension must remain loaded when selecting it.

### OpenComputers voxel projector fallback

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

To update an existing installation to **3.4.0**, enter `quit` in CENTRAL's console, then run these lines in the OpenOS shell:

```sh
echo "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua" > /home/stratcom/source.txt
lua /usr/bin/stratcom.lua update check
lua /usr/bin/stratcom.lua
```

Use `service status` until it reports `running 3.4.0`. CENTRAL distributes intelligence runtime 1.3.0 to online intel nodes. Check `nodes`; if deployment is held, use `deploy INTEL-1`. Field-node reinstalls are unnecessary. Strike runtime remains 3.1.0 and defense remains 2.1.0. The native projection table additionally needs mod v1.8 on the server and clients, then a new combined scan.

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

The default source used when `--source` is omitted is `main`. These preview instructions follow the preview branch; each release manifest pins an immutable source commit. To follow future releases on this preview branch, set `/home/stratcom/source.txt` to `https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua`. Use the main `release.lua` URL after the release is merged there.

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
python3 tools/make_release.py --ref <full-source-commit> --version 3.5.0
```

Use a new version for every changed bundle. Commit `release.lua` separately so it can reference the immutable preceding source commit. A checksum validates transfer integrity; it is not a signature. Installers and update channels must come from the repository you trust.

### Radome component discovery (3.5.1)

Radar runtime 1.2.1 discovers both `ntm_radar` (standard/large radars and older radomes) and `ntm_radome` (new radomes), including hardware refresh. Update CENTRAL to 3.5.1, then run `sync` and `deploy RADAR-01` for your radar node. Reboot the radar computer after installing the renamed mod component. The radar callbacks and ABM handoff are unchanged.

### Friendly launches crossing the protected center (3.5.2)

CENTRAL now correlates a registered strike with the heading from the missile's first observed position toward the ordered target. A friendly launch may initially approach the protected center; this no longer disqualifies IFF. Matching still requires a new missile contact originating inside the protected region, horizontal motion, the configured heading tolerance, an active launch window and an unused salvo slot. Status-refreshed tracks receive the same IFF check before automatic engagement. Update CENTRAL only; node runtimes, service helpers and the mod JAR are unchanged.

### Radome payload classification

With the updated mod and radar runtime, Advanced Radome observations include `NUCLEAR` or `THERMONUCLEAR` for recognized missile warheads, and STRATCOM adds that classification to radar/defense type labels. Missile tier and automatic-defense eligibility remain unchanged. Custom nuclear and thermonuclear bunker-buster warheads are classified from their payload data; unknown and conventional payloads are not inferred nuclear. Standard radars retain their old detection capability, and older callbacks remain supported. These changes require deploying the updated radar runtime and CENTRAL alongside matching mod JARs on server and clients.
