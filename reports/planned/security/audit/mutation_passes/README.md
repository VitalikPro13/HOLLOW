# Mutation passes (sessions 27 to 33)

The record behind every "mutation N/N killed" in a finding file. Each script breaks one
security check in the code of its day (an exact source replacement), runs the tests named
for that check, expects them to FAIL, and restores the file byte for byte. A check whose
tests still pass when it is broken is a check nothing guards.

The replacements match the source of the session that wrote them, so a script will not run
against today's tree as is; read it for what was mutated and which test killed it. The
names are kept as the finding files cite them (`tmp_<session>_<area>_mutate.py`).

| Script | Session | What it covers |
|---|---|---|
| `tmp_id1_mutate.py`, `tmp_id1r_mutate.py` | 21-25 | design ID-1 and ID-1R (rosters, the phrase, relay rosters) |
| `tmp_s27_mutate.py` | 27 | HOL-SEC-083..090 |
| `tmp_d1_mutate.py` | 28 | HOL-SEC-091, door-proof rooms |
| `tmp_d3_mutate.py` | 29 | HOL-SEC-092..095 |
| `tmp_d5_mutate.py` | 30 | HOL-SEC-096, proven kill-list slots |
| `tmp_s31_*_mutate.py` | 31 | HOL-SEC-114..117 and the Olm encrypt-in-turn fix |
| `tmp_s32_*_mutate.py` | 32 | HOL-SEC-118..125, the phase B guard tests, the recovery pool, the live relay test (`relay` runs on Linux) |
| `tmp_s33_*_mutate.py` | 33 | HOL-SEC-121 (`join`, 35/35; `join_relay`, 5/5 on Linux), HOL-SEC-126/127 (`relay`, 21/21 on Linux plus 15/15 with `--mock`), the HOL-SEC-123 residual (`conf`, 17/17), the Olm read marks (`olm`, 19/19), the join timers and flaky pair (`flaky`, 8/8 killed 3 of 3 under load) |
