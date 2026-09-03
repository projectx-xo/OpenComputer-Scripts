# Automatic ABM Defense Design

**Goal:** Allow STRATCOM CENTRAL to automatically engage verified inbound radar tracks using `ABM-A1`.

## Scope

CENTCOM owns all autonomous decision-making. `ABM-A1` remains a dumb defense node using the existing single-launcher runtime. `RADAR-01` continues to supply persistent track updates.

## Threat qualification

A radar track is eligible only when its HBM type ID is 0 through 9. Type 10 (anti-ballistic), 11 (player), 12 (artillery), 13 (special), and unknown types are excluded from automatic engagement.

CENTCOM uses a configured defended circle (`defense protect <x> <z> <radius>`). Horizontal track position/velocity are projected forward. A track is inbound when its future closest approach is ahead of it and that closest approach intersects the defended circle. A track must qualify across multiple radar updates before engagement.

## Engagement

Automatic defense starts OFF on each CENTCOM boot. `defense auto on` enables it only after a protection zone has been configured.

The designated interceptor node is `ABM-A1`. It must be online, running, ready, and report `hbm:item.missile_anti-ballistic` before CENTCOM may engage.

For a qualified track, CENTCOM creates one engagement record, sends ARM to `ABM-A1`, waits for the ARM acknowledgement, then sends LAUNCH to a short-lead predicted X/Z intercept point. A track cannot receive duplicate simultaneous engagements.

Track loss after firing is recorded as `TRACK_LOST`; a surviving track is recorded as `MISS` after a post-launch observation window. Re-engagement is rate-limited by a cooldown.

## Operator commands

- `defense protect <x> <z> <radius>`
- `defense auto on|off`
- `defense status`
- `engagements`

## Safety behavior

- Automatic mode defaults OFF after restart.
- No engagement without a configured protected circle.
- No engagement of player, artillery, special, anti-ballistic, or unknown radar types.
- No engagement if ABM-A1 is offline, stopped, not ready, or loaded with the wrong missile.
- Existing manual `arm`, `disarm`, and `launch` commands remain available.
