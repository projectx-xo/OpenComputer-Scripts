# Silo group loading and fuel recovery

A strike node such as `SILO-S3` is a group of launchers. CENTRAL sends preparation commands over the existing STRATCOM communications link. Missiles travel through the ME network to that group's local interfaces. Fuel stays in the group's propellant storage and travels through local connections.

The implementation adds no wireless material transport and does not change the communications protocol's authentication properties.

## Physical setup

For each launcher:

1. Connect its core to the node's OpenComputers network using an adapter, as for existing launch control. Both `ntm_launch_pad` and `ntm_custom_launch_pad` are supported. A custom missile still needs the correct pad size, power and designator.
2. Place an OC **block transposer directly against the launcher core**, normally underneath it. A multiblock dummy port, robot upgrade or remote inventory is not sufficient for this mapping. Each launcher uses its own transposer.
3. Put a full-block ME interface against another transposer face and connect it to the central ME network. Connect an OC adapter to that interface too, so the node can see its `me_interface` component. Reserve one interface configuration slot for STRATCOM's missile requests. Use a dedicated interface; other reserved slots can stock solid rocket fuel if needed.
4. Choose a return-inventory side. This can be the same ME interface, which imports returned missiles into the network, or a separate chest drained by an ME import bus. A full or blocked return stops the operation without discarding items.
5. Connect the remaining transposer faces to local propellant tanks, one fluid per tank. Use **buffer mode** for survival storage, permitting both withdrawal and return. Preselect the correct fluid on empty return tanks with an identifier. STRATCOM reads these faces and selects the matching fluid automatically. It never mixes fluids or empties an unrelated tank to make space.
6. For shared bulk storage farther away, use dedicated, filtered fluid connections and local tanks at the transposers. Return connections must also lead back to S3's storage. The software controls transfers at the transposer; it does not reconfigure Ender IO conduit filters. Do not attach uncontrolled item automation to launcher inventories.
7. Install a database upgrade in an adapter connected to the same OC network. Each named loadout reserves a database entry containing an exact missile example, including damage and NBT. Keep the database connected and unchanged.

OC side numbers are world-relative: `0` down, `1` up, `2` north, `3` south, `4` west, `5` east. Mapping validates the physical transposer-to-core connection, and ME binding validates the interface at the supply face. This verification supports the installed OC block transposer and full-block AE2 interface drivers; unsupported drivers fail closed.

For the common two-fluid case, a transposer below a core can have an ME interface to the north and fuel/oxidizer tanks east and west. Return through that ME interface or a south-side chest. There are at most four directly adjacent fuel faces when supply and return share a side. Provide the fluids required by the group's selected loadouts; adding a new loadout does not physically build additional tank connections.

## Configure S3 from CENTRAL

Use `hardware SILO-S3` to list launcher indices, transposers and database addresses. The node must be disarmed and idle for mapping and preparation. Replace the example address labels below with full component addresses.

```text
logistics SILO-S3 map 1 TRANSPOSER_ADDRESS 1 2 2
logistics SILO-S3 me 1 ME_INTERFACE_ADDRESS 1
```

This maps launcher 1 to a transposer whose upper face touches the core, uses its north face for ME supply and returns, and reserves ME interface configuration slot 1. Map each remaining launcher the same way with its own addresses. Existing inventory-controller mapping remains available for launchers without logistics configuration. A logistics mapping uses its transposer to inspect the missile slot.

Temporarily stock an example missile in the supply interface (or place it in an export inventory). If it is in supply inventory slot 1, capture its design:

```text
logistics SILO-S3 profile atlas 1 1 DATABASE_ADDRESS 1
```

Arguments are profile name, example launcher, source inventory slot, database address, database slot. Profile names use letters, numbers, underscores or hyphens, up to 32 characters. Use an empty database slot for a different design. Profiles never overwrite a different saved database entry. A changed or missing database entry blocks preparation and managed launches.

The interface binding is optional: an already-stocked ME export chest can be used as supply without it. With binding, STRATCOM requests one matching missile from ME as each launcher loads and clears only its reserved configuration slot after transfer. Other interface configuration slots are preserved. Missing stock waits up to the operation's deadline. This requests stored missiles; it does not initiate ME autocrafting. Custom solid-fuel missiles also need `hbm:item.rocket_fuel` stocked in the supply inventory.

## Prepare, inspect and reclaim

```text
logistics SILO-S3 prepare atlas 3
logistics SILO-S3 status
status SILO-S3
logistics SILO-S3 reclaim 1
logistics SILO-S3 reclaim all
logistics SILO-S3 cancel
```

`prepare` assigns the profile to the first requested number of present, mapped launchers in saved index order. It validates the group, persists assignments, locks the pads, and then works through them one at a time:

- Retain an already-correct missile and top up its required fuel, or drain the previous liquids before returning an old missile.
- Return recoverable solid fuel as rocket-fuel items on custom pads. Any remainder smaller than one 250-unit item stays in the machine for future use.
- Request the exact missile from ME, transfer one item, and verify its design.
- Fill only the missile's actual fuel requirements, with transfers capped at 16,000 mB per step. Some missiles need two fluids, xenon missiles need one, and ordinary solid missiles arrive prefueled.
- Wait for power, designator and launcher readiness, then leave the pad in `hold` and report `PREPARED`.

The loop advances at most once every 0.25 seconds, examines at most 16 inventory slots per step, and allows 180 seconds per launcher. A missing fluid, full return, incompatible missile, disconnected component, changed design or failed transfer stops the group and reports the reason. Previously completed transfers remain in their actual inventories. Fix the issue and issue `prepare` or `reclaim` again; there is no blind replay or automatic retry after a restart. `stop`, `disarm` and `cancel` stop active logistics work. Detaching the console leaves the service and an active job running.

`reclaim` empties the selected launcher's liquids and returns its missile to the return inventory. It does not release the launch interlock. Creative fuel tanks remain infinite sources; they do **not** accept returns. Provide a finite tank of the same fluid with room for reclaimed contents when using creative supply.

Preparation never arms or launches a missile. Managed pads retain a saved hardware interlock against redstone and ordinary launch callbacks. Existing CENTRAL `arm`, `launch` and confirmed `strike` workflows use the service-aware launch callback for these pads; a successful shot returns to `hold`. Runtime or world restart retains the interlock and does not recreate an old preparation job or launch confirmation.

## Deployment and checks

These commands require this modified HBM build plus the updated `central/central.lua` and `runtime/strike.lua`. Install the modified HBM build in the game instance and deploy the matching CENTRAL and strike scripts to the in-game computers. The published installer does not acquire uncommitted code. No release manifest, version bump, publishing or live-node deployment is performed by this feature change.

`tests/logistics_test.lua` exercises the production runtime with simulated OC boundaries. `tests/strike_integration_test.lua` also checks CENTRAL logistics replies/errors alongside the existing launch-confirmation sequence. Test both Lua 5.2 and 5.3 following `TESTING.md`.

Before operating a real group, smoke-test one launcher: capture a design, prepare, compare fuel totals, reclaim to ME/local tanks, fill the return tank completely and verify the hold, disconnect a component, and restart both OpenOS and the world during preparation. Check custom missile NBT distinctions, pad size, redstone inhibition, local fluid filters and ME replenishment in the actual build. Automated mocks cannot verify physical placement, chunk loading or server scheduling.
