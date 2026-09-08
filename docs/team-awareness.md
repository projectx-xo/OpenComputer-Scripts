# BaseCenter team awareness

**Update correction (3.10.0):** bootstrap code updates with the application bundle. Reinstalling it is unnecessary. Use [the fleet update procedure](easy-updates.md); local reinstall applies only to actual stable service-helper changes.

STRATCOM 3.9.0, bootstrap 3.3.0 and tjHBM-NTM 1.15 add team identification for registered HBM launch pads (including custom pads), radars and Satellite Ground Stations. BaseCenter 1.0 supplies teams, team chat, colours and its player friendly-fire rules. Its required UniMixins dependency must also be installed. No BaseCenter objective is required: keep `preventNoTeamJoins=false` and `kickTeamMembersOnBaseCenterDeath=false` in the `teams` category of `config/hbmbasecenter.cfg`. This setup retains BaseCenter's default combat-logging behavior; do not use its base-spawn commands if you do not want base-driven respawns.

## Set up

1. Install the same mod versions on clients and the server; restart Minecraft. An operator creates teams and adds players using BaseCenter's `/team` command and its built-in usage help.
2. Register each existing asset while standing within 16 blocks: `/hbmasset <x> <y> <z> <label>`. For example, `/hbmasset 100 64 200 RADAR-01`. Select a pad/radar/station block; multiblock parts resolve to their core. Registration uses your current BaseCenter membership, not a team name supplied by a computer. Labels are one argument, up to 32 printable characters. Registration is explicit, not automatically inferred from a cable connection or network key.
3. On CENTRAL, set the viewing team's exact name: `team Blue`. This preference survives application updates. It selects the perspective for labels; it does not change any BaseCenter membership or grant access.
4. Update CENTRAL to 3.9.0. Reinstall field-node bootstrap helpers to 3.3.0 with the service stopped, preserving existing network/key settings. Ordinary runtime deployment alone does not replace bootstrap helpers. `nodes`, `status <node>` and `assets` show asset labels, team names, positions and dimensions after the next status poll.

Registered machines store the owner's UUID/name and label in their own NBT. Membership is resolved through BaseCenter's current username-to-team map, so team membership and name changes are reflected on later reports. BaseCenter itself uses player names; after a Minecraft username change, have the registering owner/operator re-register affected machines. An existing registration can only be replaced by its registering owner or an operator. Registration is an identification label, not land ownership enforcement or theft prevention.

## Gameplay

Same-team assets show FRIENDLY. Other registered teams show OTHER TEAM, not automatically hostile. Missing registration, missing BaseCenter support or unavailable membership stays UNKNOWN. Disconnected/stale assets are labelled LAST KNOWN; last-known coordinates can still produce an explicitly stale warning.

Launch and strike plans warn when the target lies within 32 horizontal blocks of a known friendly asset. They still use the normal confirmation and can fire at that location. This distance is an identification proximity threshold, not a calculated blast radius or a guarantee that more distant friendlies are safe. Known differing dimensions are excluded. If the launching node's dimension is unknown, warnings say so rather than silently treating all coordinates as the same dimension.

Launch-site details and completed intelligence scans identify nearby registered assets without claiming that every finding in that area belongs to that team. Registration does not reveal enemy assets across the world: CENTRAL only knows reports received from its own connected nodes. Moving missiles retain the existing radar/IFF behavior; this feature does not invent ownership for unidentified missile tracks.

No launch veto, explosion cancellation, friendly terrain immunity, claim changes or damage hooks are added. BaseCenter's player damage rules remain separate from asset identification. Other existing protection mods retain their own settings. Team identity is informational and does not replace STRATCOM's authenticated network provisioning.

Each status poll sends a separate, session-correlated identity packet (up to 16 connected components, bounded to 4 KiB), leaving weapon status payloads unchanged. Older nodes remain usable but cannot report registration. This is live/last-known awareness, not a permanent global asset database.

## Verification

Lua 5.2/5.3 regression suites cover team labels, unknown/other-team handling, dimensions, stale reports, separate status packets and a confirmed friendly-target strike that still launches. Java checks cover registration persistence and validation. Live server/client checks remain necessary: register real multiblocks, restart the world, change membership, remove BaseCenter, lose node connectivity, and deliberately confirm a strike near a friendly asset. Verify physical damage separately. Test player friendly fire and BaseCenter/UniMixins compatibility on the actual server.
