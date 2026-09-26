# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of an appliance recipe, docs/org-plan.md section 1).

## Measured 2026-09-26

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/nodebb.sh | tests/nodebb.bats (15 tests) | 100 percent under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/40nodebb | tests/boot-test.sh | integration only | thin caller of the library; runs on the real first boot |
| overlay/usr/lib/inithooks/bin/nodebb.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | tests/boot-test.sh (build step) | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the acceptance test |

`tests/coverage.sh` measures the library and fails below 95 percent; the
workflow runs it on every pull request. The appliance test runs through the
organization's `test-appliance.yml` once the self-hosted `keel-lxc` runner
exists; until then it runs by hand on the build host and its output is quoted
in the pull request (0003).

## Plan

- Keep every decision in lib/nodebb.sh so the hook stays a thin caller.
- Move the dialog helper to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
