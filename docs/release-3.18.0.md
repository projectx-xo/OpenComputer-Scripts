# STRATCOM 3.18.0 — Wait for ABM reload readiness

CENTRAL invalidates cached ABM readiness and outstanding status requests when sending a launch and receiving its result. Another engagement requires a newly correlated status reply and the pad reporting ready. Old or uncorrelated ready messages cannot bypass this gate. The pad's existing reload delay remains authoritative; no fixed extra cooldown is imposed.

Run `upgrade` on CENTRAL. No mod or runtime changes are required. Lua 5.2/5.3 suites and syntax checks passed, with regression coverage for stale, uncorrelated, reloading and ready status replies. Live salvo timing remains unverified.
