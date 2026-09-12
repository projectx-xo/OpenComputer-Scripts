# Distributed STRATCOM architecture

STRATCOM models a team-wide command network for a multiplayer war game. One protected CENTRAL computer owns operational decisions while specialized field nodes observe or execute narrowly scoped work.

| Node | Responsibility | CENTRAL uses it for |
| --- | --- | --- |
| `RADAR-##` | Detect and report local tracks | Combining friendly radar coverage and evaluating inbound threats |
| `ABM-A#` | Maintain an ordinary pad loaded with an Anti Ballistic Missile | Executing validated defensive engagements |
| `SILO-S#` | Manage offensive launchers, local ME missile supply, and local propellant storage | Preparing loadouts, reclaiming fuel, and executing confirmed strikes |
| `INTEL-#` | Operate a Combined Intelligence Satellite link | Reconnaissance scans and command-room projection data |
| Communications Satellite link | Carry authenticated STRATCOM packets | Connecting remote nodes to CENTRAL when a modem path is unavailable |

CENTRAL merges observations from every friendly radar node. Its defended-zone, track history, freshness, IFF, range, and target-identity checks decide whether an inbound contact qualifies for an ABM engagement. ABM nodes do not select targets themselves. Offensive nodes receive prepared and confirmed strike orders; automatic defense never launches a counterstrike.

Silo logistics remain physical. Missile items move through the team's AE2 network into each field's launchers, and fuel moves between that field's storage tanks and pads. SATCOM carries requests, status, and results; it never moves inventory or fluid.

Each new node classifies its attached hardware and enrolls with CENTRAL. CENTRAL assigns the lowest free conventional ID and preserves that binding across restarts. Operators may add an alias without changing the immutable ID. Empty launch pads and conflicting hardware remain unassigned until corrected.

Protocol v3 separates teams with a public network ID and HMAC-SHA-256 authentication. CENTRAL keeps the team root key; every field computer stores a key derived for its physical address. Authenticated boot epochs and sequence windows reject forged, duplicated, and replayed control traffic across both modem and Communications Satellite transports. Encryption, radio-jamming resistance, and protection after physical computer compromise are outside this boundary.
