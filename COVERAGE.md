# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe).

## Measured 2026-11-12

| File | Test | Coverage | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/bin/nodebb.py | tests/python/test_nodebb_hook.py | 100 percent of lines and branches, coverage.py | the first boot program; fakes of psql, runuser and ./nodebb |
| overlay/usr/lib/keel-nodebb/serve.py | tests/python/test_serve.py | 100 percent of lines and branches, coverage.py | NodeBB serves on the writable node only; main() and the signals are integration only |
| overlay/usr/lib/inithooks/firstboot.d/45nodebb | tests/hook.bats (7 tests) | 100 percent (16/16), kcov | declared values, a headless boot that defers to keel-init, a console, a failure of nodebb.py |
| conf.d/zz-check | tests/image-check.bats (13 tests) | 95.65 percent (66/69), kcov | each defect alone, in a fakeroot session for the owners |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats | 100 percent (137/137), kcov | not changed; it checks the published layer |
| The files of the layer | tests/layer.bats (9 tests) | grep | the plan, the pin, the lock file, the unit, the routes, the manifest |
| conf.d/main | the real-node run | integration only | CT 9385 on BR1, 2026-11-11 (handbook evidence) |
| tests/boot-test.sh | itself | integration only | the thin main of the boot test |

`tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to 95. It is only ever raised (decision 0006).
