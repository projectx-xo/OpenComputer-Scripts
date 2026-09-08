# Updating CENTRAL and nodes

From STRATCOM 3.10.0 onward, use this on CENTRAL:

```text
upgrade
```

CENTRAL checks its configured release channel, downloads and validates the bundle, and applies it when idle. The saved fleet request resumes after CENTRAL restarts and passes its startup probation. CENTRAL then requests each connected node's application update and verifies the bundle and running role runtime. Runtime synchronization/deployment happens through the existing reconciliation path; there is no separate `sync` / `deploy all` step.

```text
upgrade status
```

This shows each node as queued, updating, updated, waiting for auto-update, or needing attention. Requests run one node at a time, retry lost acknowledgments, preserve progress through CENTRAL restarts, and never replay a launch. Busy equipment waits for the normal idle gate. Stopped/maintenance intent remains stopped/maintenance; its dormant role runtime is reconciled when subsequently enabled. A completed pass can contain nodes needing attention: it does not claim they all updated.

## First transition from 3.9.0 or older

On CENTRAL, run **`update check` once**. That command already downloads **and applies** the bundle when idle; `update apply` is only needed to explicitly retry a previously rejected candidate. Once CENTRAL is on 3.10.0, use `upgrade`.

Older node bootstraps do not understand remote update requests yet. The fleet flow waits for their existing automatic updater (enabled by default for online installs, checked on startup and hourly). After the first transition to bootstrap 3.4.0, future updates are requested directly by CENTRAL. If a node has automatic updates disabled, cannot reach the release source, or does not update within the migration wait, run `update check` locally once and then retry `upgrade`. **No reinstall is needed for bootstrap updates.**

The earlier advice to reinstall node bootstrap helpers was incorrect: the service loads `bootstrap/bootstrap.lua` from the selected application bundle. This update mechanism already replaces it. Reinstallation is reserved for actual stable service/console/updater/auth-helper changes under `/usr/lib`, `/usr/bin`, or `/etc/rc.d`; this release does not change those helpers.

## Requirements and failures

Nodes download through their own Internet card and retain their configured source URL. CENTRAL does not silently change another node's release channel or copy bundles over the radio. Nodes without Internet access continue to use the existing local-bundle/offline procedure. The update covers STRATCOM software, not Minecraft mod JARs.

An offline/unclaimed node is reported separately; retry `upgrade` once it is connected. Older nodes get up to 65 minutes for the initial automatic migration. A requested node update has a ten-minute observation window; timing out does not force a restart or cancel an already staged update. If the source differs from CENTRAL, `upgrade status` reports the version mismatch rather than calling it success. Inspect the node's `update status` for download/disk problems. Existing checksum, syntax validation, activation probation and rollback protect the previous usable bundle.

CENTRAL's existing auto updater also remains enabled where configured. `upgrade` is the explicit fleet command; simply detaching the console does not stop it. It targets the node list known when the command was issued, at most 128 nodes. Run another pass for nodes discovered later.
