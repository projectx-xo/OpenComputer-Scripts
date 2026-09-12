# STRATCOM 3.6.4

CENTRAL accepts a correlated INTERCEPTED outcome from the ABM node and reports confirmed interception. Radar contact loss no longer immediately closes an engagement that has a tracked interceptor; it waits up to 30 seconds after loss for the hardware result. Legacy/untracked engagements and unresolved outcomes remain unconfirmed. Confirmed misses still require a fresh surviving target.

Update CENTRAL with update check. Install companion mod 1.12 on server and clients and restart Minecraft. Defense runtime 2.4.0 already forwards the new outcome; no runtime version bump or helper reinstall is needed. Previous interceptions cannot be retrospectively confirmed.

All Lua suites and CENTRAL syntax checks pass on Lua 5.2.4 and 5.3.6. Regression tests cover contact-loss ordering and rejection of stale request IDs. Live interception still requires in-game verification.
