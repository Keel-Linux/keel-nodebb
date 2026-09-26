# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of an appliance recipe, docs/org-plan.md section 1).

## Measured 2026-09-26

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/nodebb.sh | tests/nodebb.bats (25 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/40nodebb | tests/hook.bats (15 tests) | 96.97 percent (32/33) under kcov | the one uncovered line is inside the dialog loop, which needs a terminal |
| overlay/etc/nginx/* | tests/nginx.bats (12 tests) | not executable | asserted as content: the geo variable, the map, the listeners, the proxy headers |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (34 tests) | 100 percent (124/124) under kcov | the logic of the boot test: argument parsing, address discovery, deadlines, the HTTP and diff verdicts |
| overlay/usr/lib/inithooks/bin/nodebb.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | tests/boot-test.sh (build step) | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the three measured shell files: 99.00 percent (199/201) before the
terminal test, 99.50 percent (200/201) with it.

`tests/coverage.sh` runs the whole bats suite under kcov, measures the
library, the first boot hook and the boot test's own library, and fails below
95 percent; the workflow runs it on every pull request through the
organization's `test-shell.yml` and produces the required check
`tests / coverage` on `main`.

The appliance test runs through the organization's `test-appliance.yml` on the
self-hosted `keel-lxc` runner, which fetches the published layer from
`https://mirror.keellinux.org/layers`, verifies it, assembles it, boots it in
LXC and runs `tests/boot-test.sh` against it. Nothing is built there: the
runner has no fab, deck or buildtasks. That job produces the check
`appliance / build-and-boot`.

State of that check on 2026-09-26: **failing on a defect of the published
layer, so it is not a required status yet.** The `nodebb` layer on
the mirror (sha256 `40e3f4da`) carries the build time wrappers
`/usr/local/bin/systemctl` and `/usr/local/bin/service`, which call each other
in a loop outside a build chroot, so the first boot never gets past
`10regen-sshkeys`. The cause is the one pull request 1 fixed: the conffile
prompt failed the `root.patched` target, so fab never reached the step that
removes the build overlays, and `bt-layer` packed and published the tree
anyway (buildtasks issue 6). The recipe is fixed; the layer on the mirror is
not, because it has not been rebuilt. Once it is, this check goes green and is
added to the protection rule of `main`. Measured
before the failure, on the runner: `keel pull` of the three layers (598 MB)
7 s, `keel verify` exit 8, assemble 43 s, container started with a global
IPv6 address in 5 s.

### What the hook tests cover

The hook is executed for real against scratch directories, with PATH stubs
for `systemctl`, `nginx`, `redis-cli`, `chown` and `runuser` and a fake
`./nodebb`, so no test needs root, a network or a live service: the setup
call and its arguments, the `config.json` patch, the rendering of
`/etc/nginx/conf.d/nodebb-proxy.conf` from `APP_TRUSTED_PROXY`, the `nginx -t`
check, the service calls, the asset build switch, both idempotence paths, the
refusal of an address nginx would reject, the empty trusted proxy, the domain
fallback, the missing password with and without a terminal.

## Plan

- Rebuild and publish `nodebb` now that pull request 1 fixed the conffile
  prompt, then require `appliance / build-and-boot` on `main`. Separately,
  `bt-layer` should refuse to pack a build whose `make` failed (buildtasks
  issue 6), so a broken layer cannot reach the mirror again.
- Keep every decision in lib/nodebb.sh so the hook stays a thin caller.
- Move the dialog helper to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
