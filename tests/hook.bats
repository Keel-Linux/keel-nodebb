#!/usr/bin/env bats
# The first boot hook firstboot.d/45nodebb (decision 0004), run for real
# against scratch directories. bin/nodebb.py and systemctl are PATH stubs
# that record how they were called; the Python of nodebb.py has its own
# tests (tests/python). Nothing here needs root, NodeBB or a database.
#
# Whether anybody can answer the console is inithooks' rule (lib/console.sh,
# as for 35pgsqlpass and 45odoo): tty1 of an LXC container is a terminal
# nobody is attached to, so a test of standard input is not enough.

# Each test runs in its own subshell, so a change of the environment in
# a test stays in that test. The stub and tree bodies are in single quotes
# on purpose: they expand where they run.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/45nodebb"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin" "$scratch/inithooks/lib"
    cat > "$scratch/inithooks/lib/console.sh" <<'CON'
console_unattended() { [[ "${INITHOOKS_UNATTENDED:-no}" != "no" ]]; }
console_deferred() { echo "INFO: [$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >&2; echo "$1" >> "$DEFERRED"; }
CON
    cat > "$scratch/inithooks/bin/nodebb.py" <<'PY'
#!/bin/sh
echo "nodebb.py $* APP_PASS=${APP_PASS-unset} DB_PASS=${DB_PASS-unset} NODEBB_SECRET=${NODEBB_SECRET-unset}" >> "$CALLS"
exit "${NODEBB_PY_STATUS:-0}"
PY
    chmod +x "$scratch/inithooks/bin/nodebb.py"
    printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\n' > "$scratch/bin/systemctl"
    printf '#!/bin/sh\necho node.example.org\n' > "$scratch/bin/hostname"
    chmod +x "$scratch/bin/systemctl" "$scratch/bin/hostname"
    PATH="$scratch/bin:$PATH"

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export DEFERRED="$scratch/deferred"
    export INITHOOKS_UNATTENDED=no
    unset APP_PASS DB_PASS APP_DOMAIN APP_EMAIL APP_ADMIN_USER NODEBB_SECRET
    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF
}

@test "declared values go to nodebb.py, the passwords in the environment" {
    cat > "$INITHOOKS_CONF" <<'CONF'
export APP_PASS=app-secret
export DB_PASS=db-secret
export APP_DOMAIN=forum.example.org
export APP_EMAIL=boss@example.org
export APP_ADMIN_USER=boss
CONF
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "nodebb.py --domain=forum.example.org --email=boss@example.org --admin=boss APP_PASS=app-secret DB_PASS=db-secret NODEBB_SECRET=" ]
    [ "$(sed -n 2p "$CALLS")" = "systemctl try-restart nodebb.service" ]
    [ ! -f "$DEFERRED" ]
}

@test "with no domain the name of the machine is the domain" {
    printf 'export APP_PASS=a\nexport DB_PASS=b\n' > "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$(head -1 "$CALLS")" == "nodebb.py --domain=node.example.org --email= --admin= "* ]]
}

@test "a secret of the spec goes to nodebb.py" {
    printf 'export APP_PASS=a\nexport DB_PASS=b\nexport NODEBB_SECRET=s3\n' > "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$(head -1 "$CALLS")" == *"NODEBB_SECRET=s3" ]]
}

@test "a headless first boot with no app password asks nothing and leaves it to keel-init" {
    printf 'export DB_PASS=b\nexport APP_DOMAIN=forum.example.org\n' > "$INITHOOKS_CONF"
    export INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEFERRED")" = 45nodebb ]
    [[ "$output" == *"no APP_PASS: NodeBB stays closed until keel-init asks it"* ]]
    [ ! -f "$CALLS" ]
}

@test "a headless first boot with DEFAULT passwords names both" {
    printf 'export APP_PASS=DEFAULT\nexport DB_PASS=default\n' > "$INITHOOKS_CONF"
    export INITHOOKS_UNATTENDED=yes
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no APP_PASS DB_PASS:"* ]]
    [ ! -f "$CALLS" ]
}

@test "with a console and no password nodebb.py runs and gives its answer" {
    : > "$INITHOOKS_CONF"
    export NODEBB_PY_STATUS=1
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$(head -1 "$CALLS")" == "nodebb.py --domain=node.example.org"*"APP_PASS=unset DB_PASS=unset"* ]]
    # nothing restarts a NodeBB that the hook did not configure
    [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "with no conf file the hook still runs" {
    rm -f "$INITHOOKS_CONF"
    export APP_PASS=a DB_PASS=b
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$(head -1 "$CALLS")" == *"APP_PASS=a DB_PASS=b"* ]]
}
