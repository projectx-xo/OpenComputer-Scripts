# STRATCOM 3.11.0 — Node dashboards

Field nodes now open a coloured ASCII status page instead of the command console. CENTRAL keeps its console. The page shows node identity, team, recent CENTRAL contact, runtime and update state, role-specific equipment and recent events. Status snapshots refresh without issuing operational commands; stale data is marked.

- **C** opens command input; **Q** detaches without stopping the service.
- **Up/Down** scroll; `dashboard` returns from a node console.
- `stratcom console` opens command input directly; existing one-shot commands still work.

Run `upgrade` on CENTRAL and check `upgrade status`. When the nodes finish, quit and reopen any existing node console with `stratcom` (or `lua /usr/bin/stratcom.lua`). No helper reinstall is needed for the shipped console: bootstrap 3.5.0 migrates that launcher, preserving a backup. Custom launchers are left untouched. The dashboard itself lives in the application bundle. An older bundle without a dashboard falls back to the console. This does not change OpenOS boot-screen behaviour.

Validation: Lua 5.2 and 5.3 regression suites and syntax checks, including dashboard rendering bounds, console routing, snapshots and migration failure cases. Live OpenOS screens, multi-GPU binding and scheduling remain to be checked in game.
