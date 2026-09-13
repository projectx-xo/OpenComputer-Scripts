# STRATCOM 3.10.0 — Fleet updates

Use `upgrade` on CENTRAL to update CENTRAL and request node bundle updates, with `upgrade status` for progress. The request survives CENTRAL's restart, respects idle/maintenance behavior, verifies node versions and uses existing runtime reconciliation. Bootstrap 3.4.0 adds claimed-controller-only, correlated remote update/status commands.

For the initial transition, run `update check` once on CENTRAL. Older nodes can pick up this release through their existing hourly auto updater; if that is disabled, run `update check` locally once. Bootstrap code already updates through application bundles: earlier reinstall instructions were unnecessary. This release changes no stable service helpers.

Nodes require their own Internet access and keep their configured release source. Offline/old/different-channel/busy nodes are shown individually; no forced restarts, launch replay or mod-JAR installation occurs. See [the update guide](https://github.com/projectx-xo/OpenComputer-Scripts/blob/codex/stratcom-reliability/docs/easy-updates.md).

All Lua suites and syntax checks pass under Lua 5.2 and 5.3, including saved progress, central probation, correlated retries, initial legacy migration, runtime reconciliation and claimed-controller enforcement. Live OpenOS scheduling, downloads and modem behavior still need in-game verification.
