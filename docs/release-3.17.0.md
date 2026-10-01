# STRATCOM 3.17.0 — Counterstrike follow-up scans

Confirmed counterstrikes that receive a successful launch acknowledgment queue an intelligence reassessment after 180 seconds plus salvo spacing. A free intelligence node scans the site and checks launch hardware findings. It reports hardware still detected or no hardware detected, with destruction explicitly unconfirmed. Completed snapshots can be displayed using `hologram show <intel-node>` and `hologram terrain on`.

The fixed delay is not impact confirmation. Busy scanners are respected; unavailable scanners expire after a bounded wait. Pending assessments are not replayed across CENTRAL restart. Scan failure and incomplete information must not be treated as confirmed destruction. No automatic second strike is fired.

Run `upgrade` on CENTRAL. Lua 5.2/5.3 suites and syntax checks passed, including delayed rescans of verified sites, preserved target coordinates and conservative result labels. Live timing and projection checks remain unverified.
