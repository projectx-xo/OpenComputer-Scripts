# Verification

Automated tests run real STRATCOM scripts and modules with simulated OpenOS component, disk, modem and thread boundaries. They are useful regression tests, not a Minecraft emulator. No live-server latency or TPS improvement is claimed.

The current release passed 65 scenarios under Lua 5.2.4 and Lua 5.3.6, plus syntax checks.

## Local checks

Run every `tests/*_test.lua` using Lua 5.2 and Lua 5.3. Compile every shipped Lua file with the corresponding `luac -p`. The optional workflow in `docs/ci/lua-checks.yml` repeats those checks once installed under `.github/workflows/`.

The tests include failure injection for missing downloads, bad checksums/syntax, interrupted application-pointer writes, interrupted node promotion, failed disk close, candidate startup/tick failure, delayed replies, retired radar sessions, stale samples, wrong deployment IDs and lost maintenance commands. Inventory and satellite tests use the HBM callback argument/return layouts read from the mod source.

## In-game smoke procedure

Use an idle CENTRAL and one node before updating the rest of a server.

1. Install with the existing node ID/role. Verify `stratcom doctor` reports boot enabled and the expected bundle. On CENTRAL, `nodes` and `doctor <node>` should show the new bootstrap and runtime.
2. Reboot the two test computers. They should start without a shell command. Detach and reattach the console; network handling should continue.
3. Remove Internet access and reboot again. Installed programs should start; online-update failures should appear only in logs. An offline `--bundle` installation should not try Internet requests.
4. Issue `status <node>` over a relayed modem path. Confirm current data appears or an explicit timeout is shown. Stop a node, wait several heartbeats, and reboot it: it should remain stopped until explicitly resumed.
5. Enter maintenance, drop the initial command packet if a test harness is available, and verify reconciliation converges on maintenance. Disarm before mapping pads/controllers; verify labels and payloads against physical inventories.
6. Install a newer candidate while idle. Check the old node runtime remains active during transfer, and inspect `update status` and `logs`. An armed node or active scan should defer application replacement. Use a deliberately broken candidate only in the test environment to exercise rollback.
7. Restart a radar runtime while tracking an object. Old IDs must not inherit friendly classification. Disconnect radar updates: cached observations must not qualify new engagements. Lost contact after an engagement must remain unconfirmed.
8. On an intelligence node, run `scan 508 1710`, wait for `COMPLETE`, then inspect `scan results` and `scan structure`. Compare target IDs/coordinates with known blocks. Repeat through CENTRAL using `scan <node> ...`. A non-combined satellite must be rejected.
9. Connect a Tier 2 hologram projector to CENTRAL, with only the field node connected to the combined-satellite relay. Complete a scan from CENTRAL and another from the field-node console. Both should automatically display sampled structures and equipment on CENTRAL's projector. Compare cyan/amber samples and red finding bounds against console coordinates; use `hologram status` to read the model scale.
10. Repeat with a Tier 1 projector. Check a large scan, an empty scan, and a same-coordinate rescan. Confirm `hologram clear` stays clear until another completion or `hologram show <node>`. Disconnect the projector during a transfer; scans and commands should keep working. Reconnect and use `show` if a drawing error occurred. With multiple projectors, bind one and verify the binding survives a CENTRAL restart. Drop modem replies and check that model transfer times out without an endless retry loop.

Native OpenOS thread scheduling, physical component placement, chunk loading, radio loss and the server's exact mod build still need this smoke test. Service helpers are stable across application updates; rerun the installer with the service stopped when upgrading those helpers.
