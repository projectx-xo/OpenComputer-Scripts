# STRATCOM 3.6.1

Fix automatic intelligence enrollment when a connected Combined Intelligence Satellite ground station is absent from the accepted communications-transport list. Hardware classification now enumerates live ntm_satlink components and invokes getType directly. A communications relay alone still does not qualify as intelligence hardware. Live enumeration also detects ground stations added after bootstrap startup.

Bundle/CENTRAL: 3.6.1. Bootstrap: 3.1.1. Role runtimes are unchanged from 3.6.0. No mod update is required for this fix.

On the affected pending node, run update check and allow activation to finish, then check doctor. CENTRAL can also update check to obtain 3.6.1. Run discover on CENTRAL; the pending node should acquire its intelligence identity automatically. Existing names and hardware mappings are preserved. If the service helpers are already from 3.6.0, reinstalling them is unnecessary.

All test suites and syntax checks passed on Lua 5.2.4 and 5.3.6, including classification with no accepted SATCOM transport proxies. Actual in-game enrollment still needs verification.
