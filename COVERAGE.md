# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of an appliance recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/nodebb.sh | tests/nodebb.bats (25 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/40nodebb | tests/hook.bats (15 tests) | 96.97 percent (32/33) under kcov | the one uncovered line is inside the dialog loop, which needs a terminal |
| overlay/etc/nginx/* | tests/nginx.bats (12 tests) | not executable | asserted as content: the geo variable, the map, the listeners, the proxy headers |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (41 tests) | 100 percent (137/137) under kcov | the logic of the boot test: argument parsing, address discovery, deadlines, the HTTP and diff verdicts |
| bin/keel-archive-check | tests/archive-check.bats (25 tests) | 100 percent (52/52) under kcov | the build time check: the archive copy in the build tree is the live archive, the source entry names the keyring through signed-by, nothing says trusted=yes, and the signature on the copied InRelease verifies against the staging key (tracker#7) |
| conf.d/zz-project-packages | tests/project-packages.bats (14 tests) | 100 percent (31/31) under kcov | the build time check that each project package is the candidate of the archive and a project build, and that the archive copy, its source entry and the staging keyring leave the image |
| overlay/usr/lib/inithooks/bin/nodebb.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | tests/boot-test.sh (build step) | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the five measured shell files: 99.66 percent (295/296) before the
terminal test, 100 percent (296/296) with it, over 132 bats tests.

`tests/coverage.sh` runs the whole bats suite under kcov, measures the
library, the first boot hook, the boot test's own library and the two build
time checks, and fails below 95 percent; the workflow runs it on every pull
request through the organization's `test-shell.yml` and produces the required
check `tests / coverage` on `main`.

The appliance test runs through the organization's `test-appliance.yml` on the
self-hosted `keel-lxc` runner, which fetches the published layer from
`https://mirror.keellinux.org/layers`, verifies it, assembles it, boots it in
LXC and runs `tests/boot-test.sh` against it. Nothing is built there: the
runner has no fab, deck or buildtasks. That job produces the check
`appliance / build-and-boot`.

### What the gate found once the layer booted (2026-09-27)

With the republished chain the gate pulls, verifies, assembles and boots, and
the whole hook chain runs. Three defects surfaced behind the one that had been
hiding them, and all three are fixed:

1. `redis-server.service` failed with `status=226/NAMESPACE`: the container
   config asked for no apparmor profile, so systemd could not give the unit a
   mount namespace.
2. nginx refused to start on `ssl_ciphers 'ZZ_SSL_CIPHERS'`, an unsubstituted
   mark. Fixed in buildtasks (`layer_needs_ssl_ciphers` now scans the child's
   overlays) and the layer was rebuilt.
3. `firstboot.d/40nodebb` never returned. The layer ships the plain appliance
   `inithooks.service`, which runs the hooks with `StandardOutput=tty` on
   `/dev/tty1`; a container image gets a unit that logs to syslog and the
   console instead. Nothing reads tty1 in a container nobody has attached to,
   so `./nodebb setup` filled the terminal buffer and blocked in
   `n_tty_write`. `bt_mark_container` now does what a container build does:
   the marker, `REDIRECT_OUTPUT=true`, and a drop-in that puts the unit's
   output on the journal.

Measured on the build host against the published chain, with all three in
place: the first boot completes through `98finalize`, `[40nodebb]
successfully completed`, port 80 answers 307 to https and port 443 answers
200 with `<title>Home | NodeBB</title>` over IPv6.

State of that check on 2026-09-27: **green.** Run 36290439227 on `main`,
against the chain published that morning:

    keel verify exited 9: every layer matches
    boot-test: assembling nodebb from https://mirror.keellinux.org/layers
    boot-test: container address fc42:...:9e24
    boot-test: first boot finished
    boot-test: http://[fc42:...:9e24]/ answered 307 https://[fc42:...:9e24]/
    boot-test: the forum answered 200, title 'Home | NodeBB'
    keel diff: no drift
    boot-test: nodebb boot test passed

Measured on the runner: assemble 33 s, a global IPv6 address 5 s after the
start, first boot finished 50 s later, the whole job under two minutes once
the layers were pulled. It is a candidate for the protection rule of `main`
now that it passes.

Four defects had to go first, each hidden by the one before it: the build
time `systemctl` and `service` wrappers that stopped the first boot at
`10regen-sshkeys` (pull request 1, and the layer rebuilt); the container's
missing apparmor profile, which kept `redis-server.service` from starting
with `status=226/NAMESPACE` (pull request 8); the unsubstituted
`ssl_ciphers 'ZZ_SSL_CIPHERS'`, which stopped nginx (buildtasks
`layer_needs_ssl_ciphers`, and the layer rebuilt again); and the first boot
writing to a `/dev/tty1` nobody reads, which blocked `./nodebb setup` in
`n_tty_write` forever (pull request 9).

### What the hook tests cover

The hook is executed for real against scratch directories, with PATH stubs
for `systemctl`, `nginx`, `redis-cli`, `chown` and `runuser` and a fake
`./nodebb`, so no test needs root, a network or a live service: the setup
call and its arguments, the `config.json` patch, the rendering of
`/etc/nginx/conf.d/nodebb-proxy.conf` from `APP_TRUSTED_PROXY`, the `nginx -t`
check, the service calls, the asset build switch, both idempotence paths, the
refusal of an address nginx would reject, the empty trusted proxy, the domain
fallback, the missing password with and without a terminal.

### What the build time checks cover

The two build time scripts also run for real, against scratch trees, with
`dpkg`, `dpkg-query` and `apt-cache` as PATH stubs driven by fixture files, so
no test needs a chroot, apt or root. `bin/keel-archive-check`: a faithful
copy, a copy of an older archive (the message names the version that changed),
a missing copy, a missing source index and the argument errors.
`conf.d/zz-project-packages`: the three packages at the versions the archive
offers, the same three at versions nobody has published yet (the script names
no version, so that passes unchanged), yesterday's package against today's
archive, a candidate that is not what the archive offers, an upstream build of
the same version, a package the archive does not offer, an archive that offers
two of them, a package that is not installed, a half configured one, a build
with no project archive in its source list, a distribution the archive has not
got, and the removal of the build time source with the disabled
`apt.keellinux.org` entry left in place.

## Plan

- Rebuild and publish `nodebb` now that pull request 1 fixed the conffile
  prompt, then require `appliance / build-and-boot` on `main`. Separately,
  `bt-layer` should refuse to pack a build whose `make` failed (buildtasks
  issue 6), so a broken layer cannot reach the mirror again.
- Keep every decision in lib/nodebb.sh so the hook stays a thin caller.
- Move the dialog helper to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
