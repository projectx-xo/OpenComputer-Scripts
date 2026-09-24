# Custom missile payload classification

Large Launch Pads report the installed custom missile's warhead through the second return value of `getPayloadIdentity`. The first value (`empty` or `other`) is unchanged for existing callers.

STRATCOM uses this per-launcher value for inventory displays, ready payload counts, and class-selected strikes/counterstrikes. Nuclear and thermonuclear warheads count as nuclear; conventional explosive warheads count as conventional; conventional bunker-buster warheads count as bunker. Missing or unsupported warheads remain unknown. Item-wide catalog overrides do not classify `hbm:item.missile_custom`.

Both the updated mod and STRATCOM central/strike runtime are required. Older callbacks remain usable for manual launches but cannot supply custom warhead classification. Changing the reported payload class after selecting a strike causes confirmation to reject it.

In-game validation: load nuclear and conventional custom missiles on separate pads, confirm their shared item ID but distinct payload classes, then replace a warhead and refresh status. Verify counts and class selection follow the installed warhead. No automatic launch is needed to validate classification.
