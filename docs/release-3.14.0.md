# STRATCOM 3.14.0 — Remove BaseCenter integration

Removed BaseCenter team labels from node lists, status and dashboards, equipment identity polling, team/asset commands, and BaseCenter target-proximity warnings. Existing saved team preferences are ignored. Authentication keys, network IDs, SATCOM, radar/IFF and explicit launch confirmations remain supported.

Run `upgrade` on CENTRAL to update the fleet, including bootstrap 3.6.0. No manual reinstall is required.

Lua 5.2/5.3 regression suites and syntax checks passed, including absence of team telemetry and dashboard labels and preservation of launch confirmation. Live OpenOS checks remain unverified.
