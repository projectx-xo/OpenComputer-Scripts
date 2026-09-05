# Verification

Automated tests run real STRATCOM scripts and modules with simulated OpenOS component, disk, modem and thread boundaries. They are useful regression tests, not a Minecraft emulator. No live-server latency or TPS improvement is claimed.

The test suites run under Lua 5.2.4 and Lua 5.3.6, with syntax checks for both versions.

## Local checks

Run every `tests/*_test.lua` using Lua 5.2 and Lua 5.3. Compile every shipped Lua file with the corresponding `luac -p`. The optional workflow in `docs/ci/lua-checks.yml` repeats those checks once installed under `.github/workflows/`.

The tests include failure injection for missing downloads, bad checksums/syntax, interrupted application-pointer writes, interrupted node promotion, failed disk close, candidate startup/tick failure, delayed replies, retired radar sessions, stale samples, wrong deployment IDs and lost maintenance commands. Inventory and satellite tests use the HBM callback argument/return layouts read from the mod source.

Hologram tests reproduce all eight findings reported at 507,1709, including the co-located missile and launch table at 508,5,1709. Representative wall samples check cutaway visibility; they are not a captured full-world scan. Tests cover finding IDs, distinct equipment symbols, cached selection, Tier 1 isolation, all 128 findings across 16 pages, projector boundaries, legacy runtimes, and CENTRAL console routing. In-game readability still needs the smoke checks below.

### OpenOS file compatibility

OpenOS file `close()` returns no value on success. Its buffer close also discards a flush error, so file promotion must check `flush()` explicitly. The disk doubles model empty successful close returns; tests reject failed flush/close operations without replacing the previous file.

To run the installer/service tests using OpenOS's unmodified buffer code, download these two libraries from the pinned upstream commit:

```sh
mkdir -p work/openos-io
curl -fsSL https://raw.githubusercontent.com/MightyPirates/OpenComputers/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/loot/openos/lib/buffer.lua -o work/openos-io/buffer.lua
curl -fsSL https://raw.githubusercontent.com/MightyPirates/OpenComputers/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/loot/openos/lib/core/full_buffer.lua -o work/openos-io/full_buffer.lua
OPENOS_LIB=work/openos-io lua tests/service_test.lua
```

This uses the real buffer's read/write/flush/close implementation over a simulated filesystem component. Modem and thread boundaries remain simulated. It covers fresh CENTRAL installation through service startup, node runtime installation, reinstalling with a cached older updater, and failed writes.

Strike tests connect production CENTRAL and the strike runtime over a simulated modem: estimated site coordinates enter a reviewed plan, confirmation queues four launches, and launches occur at least three seconds apart while status stays responsive. Other cases cover custom-pad callbacks, invalid/duplicate plans, disarming/stopping, payload changes, and delayed ticks without bursts. CENTRAL tests retain a status response delayed six seconds and verify that only a fired ABM with an associated origin produces a counterstrike suggestion.

## In-game smoke procedure

For 3.3, connect an adapter underneath a Large Launch Pad core using mod v1.7 and verify `components ntm_custom_launch_pad`. Deploy strike runtime 3.1 and verify its inventory mapping, designator, fuel and power. Use four loaded pads to confirm the requested launch spacing and test disarming after the first shot. Check that `status` remains responsive and `logs` reports partial/cancelled results. After an ABM engagement with a detected origin, compare the suggested site with `launchsite <id>`; verify that `counterstrike nuclear 1` only creates a plan and that nothing launches until confirmation. Also check normal ABM polling and a temporarily delayed/disconnected node: fresh replies should restore readiness, while missing replies should show age/error details and retain the stale-data hold.

Use an idle CENTRAL and one node before updating the rest of a server.

1. Install with the existing node ID/role. Verify `stratcom doctor` reports boot enabled and the expected bundle. On CENTRAL, `nodes` and `doctor <node>` should show the new bootstrap and runtime.
2. Reboot the two test computers. They should start without a shell command. Detach and reattach the console; network handling should continue.
3. Remove Internet access and reboot again. Installed programs should start; online-update failures should appear only in logs. An offline `--bundle` installation should not try Internet requests.
4. Issue `status <node>` over a relayed modem path. Confirm current data appears or an explicit timeout is shown. Stop a node, wait several heartbeats, and reboot it: it should remain stopped until explicitly resumed.
5. Enter maintenance, drop the initial command packet if a test harness is available, and verify reconciliation converges on maintenance. Disarm before mapping pads/controllers; verify labels and payloads against physical inventories.
6. Install a newer candidate while idle. Check the old node runtime remains active during transfer, and inspect `update status` and `logs`. An armed node or active scan should defer application replacement. Use a deliberately broken candidate only in the test environment to exercise rollback.
7. Restart a radar runtime while tracking an object. Old IDs must not inherit friendly classification. Disconnect radar updates: cached observations must not qualify new engagements. Lost contact after an engagement must remain unconfirmed.
8. On an intelligence node, run `scan 508 1710`, wait for `COMPLETE`, then inspect `scan results` and `scan structure`. Compare target IDs/coordinates with known blocks. Repeat through CENTRAL using `scan <node> ...`. A non-combined satellite must be rejected.
9. Use CENTRAL 3.2.0 and intel runtime 1.2.0. Connect a Tier 2 hologram projector to CENTRAL, with only the field node connected to the combined-satellite relay. Complete a scan from CENTRAL and another from the field-node console. Both should automatically display the cutaway. Compare `hologram list` with every `scan <node> results <page>`: IDs, types, bounds, confidence and count must match. Select a missile, launcher and hatch in turn; the selected symbol should turn red while others turn amber. Co-located missiles and launchers must remain individually selectable. Switch between cutaway, structure and findings views; check that sampled walls open toward local +Z, disappear in findings view, and return in structure view without moving the markers. Use `hologram status` to read the scale and selected coordinates.
10. Repeat with a Tier 1 projector: selection must isolate one finding; `select all` restores the rest. Check a large scan, an empty scan, and a same-coordinate rescan. Confirm `hologram clear` stays clear until another completion or `hologram show <node>`. Disconnect the projector during a transfer; scans and commands should keep working. Reconnect and use `show` if a drawing error occurred. With multiple projectors, bind one and verify the binding survives a CENTRAL restart. Drop modem replies and check that model transfer times out without an endless retry loop. An older intel runtime should display coordinate-only bounds with an upgrade notice, without pretending to provide typed selection.

Native OpenOS thread scheduling, physical component placement, chunk loading, radio loss and the server's exact mod build still need this smoke test. Service helpers are stable across application updates; rerun the installer with the service stopped when upgrading those helpers.
