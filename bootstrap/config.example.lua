return {
    id = "SILO-S1",
    role = "strike", -- strike, defense, radar, intel
    managementPort = 4510,
    operationalPort = 4511,
    heartbeatInterval = 5,
    meshTtl = 6,
    -- Use the hardware/map commands to save actual component addresses:
    -- launchers = {
    --     {label="BRAVO", padAddress="full-pad-address",
    --      inventoryAddress="full-controller-address", side=2, slot=3},
    -- },
    -- intel nodes with several links can select one:
    -- satelliteAddress = "full-satlink-address",
}
