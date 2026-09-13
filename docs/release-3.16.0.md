# STRATCOM 3.16.0 — Compact nuclear alerts

Nuclear missile and explosion alerts show coordinates rounded to whole blocks and omit dimension/tick fields. Full precision and metadata remain available internally for scan targeting and event validation.

Run `upgrade` on CENTRAL. No mod JAR or authentication changes are needed.

Validated with Lua 5.2/5.3 regression suites and syntax checks, including negative coordinates and preserved event data.
