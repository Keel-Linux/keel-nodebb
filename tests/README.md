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
- `dialog.bats`: `overlay/usr/lib/inithooks/bin/nodebb.py` run as the hook
  runs it, output redirected, inside a pseudo terminal (`script`), with a
  stand-in for libinithooks whose dialog refuses to draw anywhere but a
  terminal: the answers go to the hook and the box to the screen.
- `archive-check.bats`: unit tests of `bin/keel-archive-check`, which the
  Makefile runs twice per build so that the copy of the project archive inside
  the build tree is the archive as it is at build time.
- `project-packages.bats`: unit tests of `conf.d/zz-project-packages`, the
  last conf script, which checks each project package against that archive.
  `dpkg`, `dpkg-query` and `apt-cache` are PATH stubs reading fixtures, so no
  chroot and no apt are needed.
- `coverage.sh`: runs each bats file under kcov and fails when any measured
  library is below `COVERAGE_THRESHOLD` (default 95).
- `instance.yaml`: the spec the test container boots from. Not the forum:
  the production spec is `keel/instance.example.yaml`.

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/nodebb.bats
    bats tests/boot-test.bats
    bats tests/dialog.bats
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
2. Marks the tree as a container build, which is what
   `bt_mark_container` does and what buildtasks' `patches/container/conf`
   does for a real container image: the marker
   `var/lib/turnkey-info/inithooks.service/lxc` that `keel inspect` reads to
   call the machine a container (`network.managed_by: host`),
   `REDIRECT_OUTPUT=true` in `etc/default/inithooks`, and a drop-in that
   gives `inithooks.service` `StandardOutput=journal`. Without the last two
   the hooks write to `/dev/tty1`, which nobody reads in a container, and the
   first hook that prints more than the terminal buffer holds blocks there
   forever.
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

### The published layer, measured

Run 36290439227 on `main`, 2026-09-27, against the chain on the mirror:
`keel verify` exit 9 (every layer matches), assemble 33 s, a global IPv6
address 5 s after the start, first boot finished 50 s later, port 80
answering 307 to https, port 443 answering 200 with the title
`Home | NodeBB`, and `keel diff` reporting no drift. The boot test passes.

Earlier runs did not get that far, and each failure hid the next one: the
build time `systemctl` and `service` wrappers stopped the first boot at
`10regen-sshkeys`; then `redis-server.service` would not start in the
container without an apparmor profile; then nginx refused the unsubstituted
`ssl_ciphers 'ZZ_SSL_CIPHERS'`; then `./nodebb setup` blocked writing to a
`/dev/tty1` nobody reads. `COVERAGE.md` records which change fixed which.
