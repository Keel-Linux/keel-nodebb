# Tests

What a test means for an appliance recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot completes
headless from an instance spec, the forum answers over IPv6, and the machine
matches the spec.

## Layout

- `boot-test.sh`: the boot test. `test-appliance.yml` (reusable workflow of
  `keel-linux/.github`) runs it on the self-hosted LXC runner after pulling
  the layers from `https://mirror.keellinux.org/layers` and checking them
  with `keel verify`. It is the thin main: assemble, mark the tree as a
  container, install the spec, the secrets and the conf, start the container,
  wait, check the forum over IPv6, `keel diff`. It builds nothing, so it needs
  no fab, deck or buildtasks.
- `lib/boot-test-lib.sh`: the logic (argument parsing, address discovery from
  `lxc-info`, waiting with a deadline, the secret files, the HTTP verdicts,
  the diff verdict), as functions with no side effects, per decision 0004.
  Same shape as the one in keel-core.
- `boot-test.bats`: unit tests of that library. `lxc-info` is a stub first in
  `PATH`; the clock and `sleep` are functions. No root, no network, no LXC.
- `nodebb.bats`: unit tests of
  `overlay/usr/lib/inithooks/lib/nodebb.sh`, the logic behind the first boot
  hook `40nodebb`.
- `coverage.sh`: runs each bats file under kcov and fails when any measured
  library is below `COVERAGE_THRESHOLD` (default 95).
- `instance.yaml`: the spec the test container boots from. Not the forum:
  the production spec is `keel/instance.example.yaml`.

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/nodebb.bats
    bats tests/boot-test.bats
    COVERAGE_THRESHOLD=100 tests/coverage.sh

`COVERAGE_DIR=coverage tests/coverage.sh` keeps the kcov reports, one
directory per measured library.

## The boot test by hand

Needs root, `keel` on `PATH`, LXC (`lxc-start`, `lxc-info`, `lxc-attach`,
`lxc-stop`), `curl`, and a bridge with IPv6 router advertisements or DHCPv6.

    tests/boot-test.sh nodebb --layers-dir https://mirror.keellinux.org/layers \
        --bridge lxcbr0

`--layers-dir` is a directory or an http(s) URL, so on the build host it is
`/mnt/builds/layers` and on a runner it is the mirror. The other useful
options are `--bridge`, `--cache-dir`, `--lxc-path`, `--name`, `--timeout`
and `--keep` (leaves the container running; then `lxc-attach -n <name>`).
`tests/boot-test.sh --help` lists them all.

What it does, in order:

1. `keel pull` and `keel assemble` the chain (core, nodejs-nginx, nodebb)
   into `<lxc-path>/<name>/rootfs`.
2. Creates `var/lib/turnkey-info/inithooks.service/lxc` in the rootfs, the
   marker `bt-container` writes and the one `keel inspect` reads to call the
   machine a container (`network.managed_by: host`).
3. Writes a random `root_password` and `app_password` under
   `etc/keel/secrets` (mode 0600) and installs `tests/instance.yaml` at
   `etc/keel/instance.yaml` and `etc/inithooks.yaml`.
4. Renders the spec into the rootfs `etc/inithooks.conf` with `keel spec
   apply`, from a copy whose secret references point inside the rootfs.
   Without the conf the first boot is not headless: `30rootpass` and
   `40nodebb` open a dialog and wait forever.
5. Writes an LXC config for that rootfs on the bridge and starts the
   container.
6. Waits for a global IPv6 address (`lxc-info -i`), then for the first boot
   to finish: `RUN_FIRSTBOOT=false` in the rootfs copy of
   `/etc/default/inithooks`, and then confconsole or an SSH banner.
7. Checks the forum over IPv6: nginx redirects port 80 to https, and
   `https://[address]/` answers 200 with a `<title>`.
8. Runs `keel diff --root <rootfs> --spec tests/instance.yaml`; exit 0 or 13
   (no drift) passes.

Measured on the runner `keel-lxc-1` on 2026-09-26: `keel pull` of the three
layers (598 MB) 7 s from the mirror on the same host, assemble 43 s.

### Known failure of the published layer

The run of 2026-09-26 does not reach step 7: the first boot stops in
`10regen-sshkeys`. The `nodebb` layer on
the mirror (sha256 `40e3f4da`) carries the build time wrappers
`/usr/local/bin/systemctl` and `/usr/local/bin/service`, which call each other
in a loop outside a build chroot, so the first boot never gets past
`10regen-sshkeys`. The cause is the one pull request 1 fixed: the conffile
prompt failed the `root.patched` target, so fab never reached the step that
removes the build overlays, and `bt-layer` packed and published the tree
anyway (buildtasks issue 6). The recipe is fixed; the layer on the mirror is
not, because it has not been rebuilt. Once it is, this check goes green and is
added to the protection rule of `main`. Until then this test fails on the
mirror's `nodebb`, which is the gate reporting a real defect rather than a
problem with the test.
