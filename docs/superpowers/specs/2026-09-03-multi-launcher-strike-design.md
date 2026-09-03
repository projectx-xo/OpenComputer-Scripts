# Multi-Launcher Strike Runtime Design

## Goal
Support one STRATCOM strike node controlling multiple HBM `ntm_launch_pad` components, beginning with `SILO-S2` containing four launch pads.

## Model
- A strike node enumerates all `ntm_launch_pad` component addresses and sorts them lexicographically.
- Launchers are numbered `1..N` in that sorted order.
- All `inventory_controller` component addresses are also sorted and paired by index with launchers. This gives deterministic mapping across normal reboots while component hardware is unchanged.
- Each launcher has independent armed state, readiness, tier, power, fluids, missile item/label/count, pad address, and inventory-controller address.
- Missile discovery scans every reachable inventory slot exposed by that launcher's paired inventory controller for `hbm:item.missile_*`. If a battery is present but no missile is found, the launcher reports `UNLOADED`.

## Commands
- `STATUS` returns node summary plus a `launchers` array.
- `ARM <launcher|all>` arms one launcher or all launchers.
- `DISARM <launcher|all>` disarms one launcher or all launchers.
- `LAUNCH <launcher> <x> <z>` launches only the selected launcher. There is intentionally no `launch all` command.
- `PING` remains unchanged.

## Central UI
- `nodes` summarizes a multi-launcher strike node as `<ready>/<total> READY` in the missile/status column when practical.
- `status SILO-S2` lists every launcher with missile, armed, ready, tier, and power information.
- Command syntax becomes:
  - `arm SILO-S2 2`
  - `arm SILO-S2 all`
  - `disarm SILO-S2 2`
  - `disarm SILO-S2 all`
  - `launch SILO-S2 2 500 -250`
- Existing single-launcher defense nodes remain compatible.

## Deployment
`runtime/manifest.lua` points `strike` to a new multi-launcher runtime and bumps only the strike runtime version. CENTCOM `sync` deploys it automatically.
