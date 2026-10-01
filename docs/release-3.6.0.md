# STRATCOM 3.6.0

This release ships automatic hardware enrollment, Communications Satellite transport, optional authenticated team networks, silo logistics, automatic intelligence verification of suspected launch sites, confirmed ABM miss re-engagement, radome payload classification, and node session/status recovery.

Versions: CENTRAL/bundle 3.6.0, bootstrap 3.1.0, strike 3.2.0, defense 2.4.0, radar 1.3.0, intelligence 1.4.0. Use HBM mod 1.11 on clients and the server for the corresponding hardware callbacks.

## Upgrade existing computers

Exit the console with `quit`. In OpenOS run `lua /usr/bin/stratcom.lua service stop`, then `lua /usr/bin/stratcom.lua service status` until stopped. Download the current installer:

```sh
wget -f "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/install.lua" /tmp/stratcom-install.lua
```

On each field computer, the generic command preserves existing identity and mappings:

```sh
lua /tmp/stratcom-install.lua node -- --source "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/release.lua"
```

On CENTRAL use `central` in place of `node`. Reboot after installation to load all replaced service helpers, then attach using `lua /usr/bin/stratcom.lua`. At CENTRAL run `discover`, `sync`, and `deploy all`. Check `nodes`, `doctor <node>`, and `status <node>`. Busy deployments wait until safe. Updating the bundle alone does not replace stable service helpers; reinstall on each machine for this release.

## New nodes

Connect supported hardware and a modem or a Communications Satellite ground station, then run the same generic `node` installer command. CENTRAL detects the hardware role and assigns the next available ID. No role or ID argument is required. An intelligence node requires a ground station tuned to a Combined Intelligence Satellite; satellite transport requires a second station tuned to the Communications Satellite shared with CENTRAL. Empty ordinary pads and ambiguous mixed hardware remain unassigned.

Existing unsecured networks remain compatible. To enable authenticated team networking, follow the README's key provisioning instructions on every computer; do not partially convert an active network.

## Verification

All Lua test suites and syntax checks pass with Lua 5.2.4 and 5.3.6. These are simulated OpenOS checks. Live client/server tests for SATCOM, enrollment, logistics, scans and interception remain necessary; see TESTING.md. The removed assembly tower is not included.
