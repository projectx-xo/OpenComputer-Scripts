# STRATCOM 3.6.5

Launch-site grouping now matches observations within four blocks of a fixed radar origin instead of averaging all launches within 100 blocks into one site. Satellite-refined target coordinates do not move that association anchor. Different dimensions do not merge. New site verification only accepts target findings within the four-block search radius, preventing a missing pad from being substituted by a nearby launcher.

Update CENTRAL with update check, confirm 3.6.5 with doctor, and repeat the launch test. No field runtime or mod update is needed. Historical grouped counts cannot be reliably apportioned among pads; existing site records are retained, and future separated origins receive their own records. Radar origins closer than four blocks can still merge; estimates are not proof of an exact launch block until verified. Delayed radar acquisition outside this radius can produce another estimate or an inconclusive scan.

All Lua suites and CENTRAL syntax checks passed on Lua 5.2.4 and 5.3.6. Regressions cover three nearby origins, repeated launches, satellite coordinate refinement, dimension separation and rejection of a neighboring pad. Live tests remain to be verified in-game.
