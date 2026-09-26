# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of an appliance recipe, docs/org-plan.md section 1).

## Measured 2026-09-26

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/nodebb.sh | tests/nodebb.bats (26 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/40nodebb | tests/hook.bats (15 tests) | 96.97 percent (32/33) under kcov | the one uncovered line is inside the dialog loop, which needs a terminal |
| overlay/etc/nginx/* | tests/nginx.bats (12 tests) | not executable | asserted as content: the geo variable, the map, the listeners, the proxy headers |
| overlay/usr/lib/inithooks/bin/nodebb.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | tests/boot-test.sh (build step) | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the acceptance test |

Total over the two measured shell files: 96.05 percent (73/76) before the
terminal test, 97.37 percent (74/76) with it.

`tests/coverage.sh` runs the whole bats suite under kcov, measures both the
library and the first boot hook and fails below 95 percent; the workflow runs
it on every pull request through the organization's `test-shell.yml`. The
appliance test runs through `test-appliance.yml` once the self-hosted
`keel-lxc` runner builds layers; until then it runs by hand on the build host
and its output is quoted in the pull request (0003).

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

- Keep every decision in lib/nodebb.sh so the hook stays a thin caller.
- Move the dialog helper to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
