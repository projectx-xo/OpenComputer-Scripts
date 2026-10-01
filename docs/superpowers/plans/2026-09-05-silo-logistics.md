# Silo group logistics

Central ME storage supplies exact missile designs through a stocked ME interface or export-bus inventory. Each launcher has an OC transposer and local fuel connections to its group's propellant storage. Wireless STRATCOM carries control/status only.

1. Add a persistent launchpad service interlock, shared ordinary/custom missile requirements, non-destructive fluid type selection, and gated Forge fill/drain. Preserve old callbacks and unmanaged behavior. Extend propellant storage to custom missile fluids.
2. Add strike-node configuration for transposer sides and exact loadout profiles using OC database entries with NBT comparison. Prepare a requested number of disarmed launchers through bounded drain, return, load, fuel, and hold phases. Report shortages/full returns, cancel on stop, and never replay jobs on restart.
3. Add CENTRAL setup, profile, prepare, reclaim, cancel, and status commands. Keep existing launch confirmations. Prepared hardware remains interlocked; an explicit launch uses an atomic service-aware callback.
4. Test conservation, simulations, wrong fuel rejection, interlocks, persistence, exact design selection, partial transfers, mapping mismatch, missing hardware, stop/restart, and CENTRAL routing. Run relevant Java tests/build and both Lua suites/syntax checks. Document physical setup and remaining in-game checks.

Completion: production APIs and commands are implemented with passing automated checks. In-game component geometry, ME stock replenishment and dedicated-server behavior require a live fixture or explicitly reported smoke-test limitations. No release/version/publishing changes are part of this work.
