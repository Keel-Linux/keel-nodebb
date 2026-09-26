# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of an appliance recipe, docs/org-plan.md section 1).

## Measured 2026-09-26

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/nodebb.sh | tests/nodebb.bats (15 tests) | 100 percent under kcov (43 of 43 lines) | every function and every branch |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (34 tests) | 100 percent under kcov (124 of 124 lines) | the logic of the boot test, decision 0004 |
| overlay/usr/lib/inithooks/firstboot.d/40nodebb | tests/boot-test.sh | integration only | thin caller of the library; runs on the real first boot |
| overlay/usr/lib/inithooks/bin/nodebb.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | tests/boot-test.sh (build step) | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the acceptance test |

`tests/coverage.sh` measures each library against the bats file that
exercises it and fails when any one is below `COVERAGE_THRESHOLD`; the
workflow runs it on every pull request with the threshold committed in
`.github/workflows/tests.yml` (100, only ever raised, decision 0006). That
job produces the required check `tests / coverage` on `main`.

The appliance test runs through the organization's `test-appliance.yml` on the
self-hosted `keel-lxc` runner, which fetches the published layer from
`https://mirror.keellinux.org/layers`, verifies it, assembles it, boots it and
runs `tests/boot-test.sh` against it. That job produces the check
`appliance / build-and-boot`.

State of that check on 2026-09-26: **failing on a real defect of the published
layer, so it is not a required status yet.** The `nodebb` layer on the mirror
still carries the build time wrappers `/usr/local/bin/systemctl` and
`/usr/local/bin/service` from the `turnkey.d/systemd-chroot` overlay, which
call each other in a loop outside a build chroot, so the first boot never gets
past `10regen-sshkeys`. `core` and `nodejs-nginx` do not carry them:
`removelists-final/turnkey` in common strips them and `bt-layer` adds them
back as `LAYER_CHILD_OVERLAYS` for a child build without stripping them from
the finished child layer. The fix belongs in buildtasks, after which the layer
is rebuilt and published and this check is added to the protection rule of
`main`. Measured before the failure: `keel pull` of the three layers (598 MB)
7 s, assemble 43 s, container started with a global IPv6 address in 5 s.

## Plan

- Fix `bt-layer` so a finished child layer is stripped the way a rootfs layer
  is, rebuild and publish `nodebb`, then require
  `appliance / build-and-boot` on `main`.
- Keep every decision in lib/nodebb.sh so the hook stays a thin caller.
- Move the dialog helper to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
