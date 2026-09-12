# STRATCOM 3.6.2

Fix CENTRAL enrollment collisions when a pending computer begins reporting its detected role. Unassigned heartbeats no longer create permanent enrollment records. Previously persisted PENDING identities with the matching physical-address prefix and unassigned role are replaced with a normal allocated identity on enrollment. Failed preference writes restore the previous record; established role and identity collision protection remains intact.

Update CENTRAL with update check, confirm bundle 3.6.2 using doctor, then run discover. A satellite node already using 3.6.1 needs no further update for this fix. No role runtime or mod update is required. Existing real node names, mappings and aliases are preserved.

All suites and syntax checks pass with Lua 5.2.4 and 5.3.6. Regression checks cover pending heartbeat persistence, existing pending-record migration, failed persistence and established-role collision protection. Live enrollment remains to be confirmed in-game.
