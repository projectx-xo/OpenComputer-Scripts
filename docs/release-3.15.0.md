# STRATCOM 3.15.0 — Release failed automatic scans

Intelligence runtime 1.6.0 reports a satellite ERROR state with the original scan request token. CENTRAL can release automatic post-blast and launch-site scan locks promptly instead of holding them until timeout. Stale request errors cannot release a different scan. This fixes the lock, not the underlying satellite scan failure.

Run `upgrade` and verify INTEL-1 reaches runtime 1.6.0. Existing locks on older runtimes expire after their normal timeout (180 seconds for post-blast scans).

Lua 5.2/5.3 suites and syntax checks passed, including error correlation, lock release, one-time failure reporting and subsequent scan acceptance. Live scan failure reproduction remains unverified.
