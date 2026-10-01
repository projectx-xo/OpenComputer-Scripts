# STRATCOM 3.19.0 — Optional automatic counterstrikes

Commands: `counterstrike salvo <1-16>` (default 1), `counterstrike auto on|off` (default off), and `counterstrike status`.

Explicitly enabling authorizes responses without per-strike confirmation for newly confirmed incoming threats to the configured defense zone. Conventional threats receive conventional payloads; nuclear/thermonuclear threats prefer nuclear, then bunker, then conventional. Ready payloads may span strike nodes. If the preferred class is short, the available quantity is fired and logged rather than mixing classes. Unknown and friendly tracks are held; known launch-site coordinates are required but may be estimates.

Settings persist. Pending jobs do not replay across restart; duplicate updates do not create duplicate responses. Stopped/maintenance nodes are excluded. Disabling drops pending jobs, but cannot recall already accepted salvos. Unknown send outcomes are not retried. Post-counterstrike intelligence reassessment is retained.

Run `upgrade`. Conventional classification additionally needs HBM v1.19 on client/server and radar runtime 1.4.0 with an Advanced Radome. No authentication changes are needed.

Lua 5.2/5.3 tests cover policy ordering, salvo bounds in command validation, partial stock, duplicates, unknown/friendly holds, expiry and disable. Live firing/scheduling remains unverified.
