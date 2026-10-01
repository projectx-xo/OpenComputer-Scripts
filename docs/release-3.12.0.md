# STRATCOM 3.12.0 — Satellite nodes

Connect a Combined Intelligence ground station and a Communications ground station to the same satellite node. The intelligence runtime now selects its station by type, so a second communications station no longer prevents scans. Multiple Combined Intelligence stations require an explicit `satelliteAddress`; an existing explicit selection is respected.

CENTRAL and the field dashboard label the intelligence role SAT. Newly enrolled satellite nodes receive SAT-# IDs. Existing INTEL-# identities and saved assignments remain unchanged; the internal runtime/configuration role remains `intel` for compatibility. This does not combine nuclear detection into that runtime.

Run `upgrade` on CENTRAL to receive bundle 3.12.0 and intelligence runtime 1.5.0. Tune the scanning station to Combined Intelligence and the communications station to Communications. CENTRAL also needs a Communications station on that same frequency for SATCOM. Both endpoints must remain loaded.

Lua 5.2/5.3 suites and syntax checks passed, including mixed station types, ambiguous intelligence stations, explicit selection and SAT ID allocation. Live two-station OpenOS scanning and communications remain unverified.
