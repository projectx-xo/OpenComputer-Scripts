# STRATCOM 3.13.0 — CENTRAL dashboard

CENTRAL now opens a coloured ASCII dashboard with service/update state, network authentication, automatic-defense state, fleet runtime versions and online status, and recent events. Field nodes retain their equipment dashboards.

Press C for the command console, Q to detach without stopping the service, or Up/Down to scroll. Enter `dashboard` to return. `stratcom console` opens the console directly. The dashboard polls read-only snapshots; it never confirms or sends operational actions.

Run `upgrade`, then quit and reopen STRATCOM on CENTRAL after activation. Known shipped console launchers migrate automatically with a backup; custom launchers remain untouched. No manual reinstall is needed. This does not change the OpenOS boot screen.

Lua 5.2/5.3 suites and syntax checks passed, including CENTRAL snapshot data, dashboard rendering and console routing. Live OpenOS display checks remain unverified.
