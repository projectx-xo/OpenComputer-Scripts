# STRATCOM 3.7.0

Strike runtime 3.3.0 automatically fills missing launch-pad inventory mappings using mod 1.13's getInventoryMapping callback. It accepts only unique controller/side pairs with a readable inventory, independently of item contents and address ordering. Saved/manual mappings and logistics mappings remain authoritative. Discovery uses a bounded 64 probes per refresh; unsupported or ambiguous layouts remain unmapped.

Install mod 1.13 on server and clients and restart Minecraft. Update CENTRAL to 3.7.0, then run sync and deploy SILO-S2 (or deploy all). Inspect hardware SILO-S2 and status SILO-S2 after deployment. No manual address pairing is needed for unambiguous stationary-adapter layouts. The callback does not support robot/drone controllers or automatically configure fuel/ME logistics.

Both Lua versions passed all suites and syntax checks. Regression tests cover four identical missile inventories with shuffled controller addresses, preservation of saved mappings, and rejection of shared controller sides. Actual OpenComputers adapter integration still needs live verification.
