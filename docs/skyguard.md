# M240 Skyguard defense node

The updated HBM mod exposes a **Skyguard OpenComputers Control Link** as
`ntm_skyguard`. Place it within 32 blocks of one parked Skyguard,
sneak-right-click to pair, then cable the link to the field computer.
The link remains bound to the same vehicle across mobilization and reload.
Driving or leaving range makes it unavailable; it never changes vehicles itself.

Updated bootstrap auto-enrolls one Skyguard link as a defense node. Defense
runtime 2.5.0 reports both live radar tracks and interceptor inventory. Updated
CENTRAL preserves both halves of that status and uses the existing authenticated
ARM/LAUNCH_ENTITY workflow, IFF policy, stale telemetry rejection and correlated
outcome reporting. Select the enrolled node using the existing `defense` controls.

After obtaining fresh status:

```text
skyguard ABM-A1 deploy
skyguard ABM-A1 filter BALLISTIC on
skyguard ABM-A1 filter MISSILES on
skyguard ABM-A1 stow
```

Configure the protected zone and enable defense using existing commands. Load
and HE-charge the vehicle first. Six dedicated rounds are reported from the
vehicle inventory; a failed launch consumes none. The 768-block spherical range
and live target UUID are checked again by the mod. Track disappearance alone
never proves an interception.

STRATCOM disables the vehicle's independent auto fire while this runtime runs and
when it stops. Console detachment does not stop the service. Stow disarms pending
node authorization. Reload does not restore an armed command or launch receipt.

`skyguardAddress` is saved in field user configuration. With multiple links,
configure this address explicitly; never connect ordinary ABM pads and Skyguard
links to the same defense computer. A missing mapped link fails closed.

These are local source changes, not a published bundle. Update bootstrap,
CENTRAL and defense runtime together; the existing stable remote installer and
immutable `release.lua` are not changed by this work.

Live acceptance: test a paired vehicle moving out/back, save/reload, deployment,
track propagation to CENTRAL, automatic interception, six-to-five ammunition,
stow, stopped-service behavior and dropped/duplicate modem messages on OpenOS.
Lua mocks alone do not establish native scheduling or modem latency.
