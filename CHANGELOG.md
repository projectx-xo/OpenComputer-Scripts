# Changelog

## 3.0.0

- Install CENTRAL and field nodes as OpenOS boot services; attach/detach a console without stopping their work.
- Start installed programs offline before update checks; replace computer reboots with supervised application restarts and rollback.
- Stage complete immutable bundles; support local offline installation and preserve existing machine configuration.
- Keep node runtimes running during transfer, validate deployment transactions, recover interrupted activation, and roll back failed startup/first-tick candidates.
- Persist stopped/maintenance intent, node aliases, defense configuration and hardware assignments.
- Wait for fresh status/scan replies; keep background output in a bounded log and retain explicit command confirmations.
- Serialize deployments, stagger/coalesce status polling, cache inventory slots, and prune message IDs independently of console input.
- Separate radar sessions and samples; reject stale/duplicate/retired telemetry and label lost contact as unconfirmed.
- Add combined-intelligence scan/progress/findings/structural commands using the HBM fork API.
- Add Lua 5.2/5.3 regression tests and an optional CI workflow; document installation, migration, diagnostics and recovery.
