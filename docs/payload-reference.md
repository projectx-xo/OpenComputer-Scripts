# HBM Payload Classification Reference

This reference is intentionally conservative. CENTCOM's local `/home/stratcom/payloads.db` remains authoritative for strike planning, and `classify` can override/add IDs in-game.

## Nuclear

HBM language resources explicitly identify these payloads as nuclear:

- `hbm:item.missile_micro` — Micro-Nuclear Missile
- `hbm:item.missile_nuclear` — Nuclear Missile
- `hbm:item.missile_nuclear_cluster` — Thermonuclear Missile

## Conventional

HBM language resources identify these as explosive missiles without a nuclear designation:

- `hbm:item.missile_generic` — Explosive Missile / Tier 1
- `hbm:item.missile_strong` — Strong/Explosive Missile / Tier 2

## Bunker

HBM language resources explicitly identify these as bunker-busting missiles:

- `hbm:item.missile_buster` — Bunker Buster
- `hbm:item.missile_buster_strong` — Enhanced Bunker Buster
- `hbm:item.missile_drill` — The Concrete Cracker

## Special / Unknown

EMP, cluster, incendiary, black-hole, tectonic, endothermic, doomsday, custom, and other unusual missiles are left `UNKNOWN` by default unless the operator explicitly classifies them. This prevents CENTCOM from silently treating nonstandard payloads as conventional or nuclear.

## In-game workflow

```text
payloads SILO-S2
classify hbm:item.missile_nuclear nuclear
classify hbm:item.missile_generic conventional
classify hbm:item.missile_buster bunker
```

Classifications are persisted on the CENTCOM computer in `/home/stratcom/payloads.db`.
