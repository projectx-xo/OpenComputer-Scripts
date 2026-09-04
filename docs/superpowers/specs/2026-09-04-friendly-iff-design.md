# Friendly Outbound IFF Design

## Goal
Prevent STRATCOM automatic defense from intercepting missiles launched by STRATCOM-controlled strike nodes while keeping unknown inbound tracks eligible for ABM engagement and launch-site inference.

## Scope
This change is centralized in `central/central.lua`. Radar and launcher runtimes remain unchanged.

## Friendly launch expectations
Whenever CENTCOM issues a launch from a strike node, it registers one or more short-lived friendly launch expectations containing:

- source node ID
- launch timestamp
- expected missile count
- commanded target X/Z
- target bearing from the protected-region center
- matching deadline
- number of remaining unmatched friendly tracks

Manual `launch` commands register one expected missile. `strike` commands register the selected salvo count.

Default matching window: 30 seconds.

## Radar-track matching
A radar track may be marked `FRIENDLY_OUTBOUND` only if all of the following are true:

1. The track is a missile-type HBM radar track (`TIER0` through `TIER20`).
2. The track was first detected inside the configured protected region.
3. The track is moving outward from the protected-region center.
4. The track heading is within 30 degrees of the commanded target bearing.
5. The track appeared within the expectation's matching window.
6. The expectation still has an unmatched missile slot.

Once matched, the track remains friendly for its lifetime.

## Defense behavior
Tracks marked `FRIENDLY_OUTBOUND` are excluded from automatic ABM evaluation. Unknown inbound missile tracks continue to use the existing closest-approach threat logic.

## Launch-site behavior
Tracks marked `FRIENDLY_OUTBOUND` are excluded from `POSSIBLE LAUNCH SITE` promotion. Unknown missile launches continue to be eligible for launch-site inference.

## Operator visibility
`tracks` should show friendly state and mission metadata, including source node and commanded target.

Example:

```text
RADAR-01  #8  TIER4  ...  FRIENDLY_OUTBOUND
           Source: SILO-S2
           Mission target: 5000,-2000
```

## Failure behavior
If no radar track matches an expectation before its deadline, the expectation expires. Expired expectations do not whitelist future tracks.

If a track only partially matches (for example, it originated in the protected region but is not heading toward the commanded target), it remains unclassified and can still be evaluated by defense.

## Safety constraints
- Do not whitelist solely because a track originated inside the protected area.
- Do not whitelist solely because a track is moving outward.
- Only STRATCOM-issued launches create expectations.
- Automated retaliation is out of scope.
