# Tests

What a test means for an appliance recipe is written in `COVERAGE.md`.

## Layout

- `hook.bats`: the first boot hook `firstboot.d/45nodebb`, with stubs of
  `nodebb.py`, `systemctl` and inithooks' `lib/console.sh`.
- `image-check.bats`: `conf.d/zz-check` against a scratch tree, in one
  fakeroot session per test, so the owners are real for the check.
- `layer.bats`: the files that no program runs in a test.
- `python/`: `nodebb.py` and `serve.py` under pytest.
- `commission.yaml`: the commissioning contract (decision 0075).
  `commission-core.yaml` is the contract of the Keel Core witness.
- `boot-test.sh`, `lib/boot-test-lib.sh`, `boot-test.bats`: the boot test
  of the published layer. It still checks the forum of the layer on
  nodejs-nginx and changes with the first layer on lnpp.

## Run

    tests/coverage.sh 95
    python3 -m pytest tests/python

The tests need `bats`, `kcov`, `fakeroot`, `python3-yaml` and `pytest`.
No test needs root, a network or a database.
