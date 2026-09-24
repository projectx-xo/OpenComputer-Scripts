# STRATCOM reliability and operator workflow

Approved in conversation: implement all six recommendations from the review of CENTRAL 2.6.0.

Keep OpenOS Lua 5.2 compatibility and existing protocol 2 routing. Add a stable RC supervisor and console client; installed central/node code runs in a detached worker and boots from disk before any network check. A versioned application bundle is downloaded and validated separately, activated with a pointer, and rolled back if startup fails. Keep user configuration outside bundles. No computer reboot, and no replay of one-shot launch commands. Preserve legacy manual execution as a migration path.

Node deployment keeps its current runtime active through transfer, validates chunks, commits with an idempotent transaction ID, starts and checks the candidate before reporting success, and restores the previous version on failure. Persist stopped/maintenance intent. CENTRAL bounds deployments to one at a time and waits for fresh replies rather than a fixed delay. Runtime STATUS requests carry an optional request token; replies echo it.

Run cache pruning independently of console input. Stagger/coalesce polling; cache known inventory slots and persist explicit hardware assignments. Radar samples carry a runtime session and sequence; old/duplicate data cannot qualify threats, and lost contact is unconfirmed.

Add a combined-intelligence satellite runtime and local/remote scan commands with status, paginated findings and structural results. Add installer, doctor, logs, update status/apply/rollback and accurate migration documentation.

Service integration contract: application chunks accept an optional options table with log(text), ready(), stopping(), nextCommand() returning {id,line}, reply(id,ok,text), and appDir (active immutable bundle directory). CENTRAL runs commands from this queue; node supports status, doctor, scan and maintenance commands. Without options, existing foreground operation remains available. No test-only interfaces in production.

Verification: Lua 5.2 syntax, real application chunks under a fake OpenOS hardware/event boundary, failed downloads, offline boot, crash rollback, update interruption, command correlation, stop persistence, duplicate/stale telemetry, inventory mapping/cache, and combined-only scan restrictions. Live Minecraft timing is not available and will be documented.
