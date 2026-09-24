# STRATCOM 3.9.0

**Update correction (3.10.0):** bootstrap code updates with the application bundle. Reinstalling it is unnecessary. Use [the fleet update procedure](easy-updates.md); local reinstall applies only to actual stable service-helper changes.

Adds BaseCenter-backed asset labels through bootstrap 3.3.0 and HBM 1.15. `team <name>` sets CENTRAL's team perspective; `assets`, `nodes` and node status show registered equipment and allegiance. Launch plans warn near known friendly assets while retaining normal confirmation and allowing the strike. Intelligence completion and launch-site detail reports cross-reference nearby registered assets.

See [setup and behavior](team-awareness.md). Field nodes need their stable bootstrap helpers reinstalled locally with the service stopped. Existing role runtimes do not need version changes. Missing or old hardware remains unknown, never implicitly friendly.

All Lua suites and syntax checks pass in Lua 5.2 and 5.3. Live OpenComputers scheduling, server gameplay and BaseCenter compatibility remain unverified.
