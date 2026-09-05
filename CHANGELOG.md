# Changelog

## 3.3.0

- Keep slow background status requests alive until their timeout instead of replacing their token every five seconds. Refresh stale ABM readiness on demand and show status age/errors.
- Support `ntm_custom_launch_pad` in strike runtime 3.1.0 using the Large Launch Pad's actual readiness, contents and designator callbacks. Mod v1.7 fixes the component's registration; connect to its center core.
- Add paced strike queues with a one-second default interval and optional 1–60 second spacing. Acknowledge immediately, report progress, and keep status commands responsive. Disarm/stop, launch failures and payload changes cancel remaining shots.
- Preserve each detected origin's association with its radar track. Suggest a counterstrike when contact is lost after an acknowledged ABM launch, keeping the intercept unconfirmed and the origin estimated.
- Add `counterstrike <class> <count> [site-id] [node] [interval-seconds]` to prepare a strike using stored coordinates, with the existing explicit confirmation step.

## 3.2.0

- Open sampled silo walls in the default hologram cutaway and keep inferred structure bounds as outlines. Add full-structure and findings-only views.
- Preserve all scan finding numbers, classifications, confidence and target counts in intel runtime 1.2.0's paged model transfer.
- Give missiles, launchers and silo hatches distinct symbols anchored at their reported coordinates, including co-located missiles and launch tables. Symbols do not imply physical object dimensions.
- Add `hologram list`, `hologram select <number|all>` and `hologram view cutaway|structure|findings`. Selection highlights one finding, or isolates it on Tier 1 projectors, using cached scan data.
- Keep legacy coordinate-only node support with an explicit upgrade notice. Add regression coverage using the eight reported findings, maximum finding pagination, boundary symbols and CENTRAL command routing.

## 3.1.4

- Fix the actual cause of the installation `nil` failure: OpenOS file close returns no value on success. Check flush errors explicitly before promoting downloaded files.
- Apply the same OpenOS write checks to node deployment, rollback and saved CENTRAL settings.
- Replace the ineffective staging retries with the updater supplied by the install source, and discard the old cached updater before starting the installed service.
- Correct the file mocks and verify installation with the unmodified OpenOS buffer libraries, including disk-full and cached-helper recovery cases.

## 3.1.3

- Retry updater staging when OpenOS reports a network failure as the literal `nil` error.

## 3.1.2

- Refresh a stale installed updater automatically when it returns an empty failure during installation.

## 3.1.0

- Display completed combined-intelligence scans automatically on a hologram attached to CENTRAL, using scan data from remote intel nodes over the modem mesh.
- Center and uniformly scale sampled structural blocks and equipment bounds; use three colors on Tier 2 and one color on Tier 1.
- Add hologram status/show/clear/bind commands and save projector bindings in CENTRAL preferences.
- Bound transfer pages, retries and drawing work; reject mismatched scan/session/request identities and leave scan commands operational without a projector.
- Upgrade intelligence runtime to 1.1.0 and add full CENTRAL and node-to-projector integration tests.

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
