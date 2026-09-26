#!/usr/bin/env bats
# The first boot hook firstboot.d/40nodebb (decision 0004): every path it
# takes runs against scratch directories, and every command that would touch
# the system (systemctl, redis-cli, nginx, runuser, chown) is a PATH stub
# that records its arguments. Nothing here needs root or a network.

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/40nodebb"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/nodebb" "$scratch/nginx"

    export NODEBB_DIR="$scratch/nodebb"
    export NGINX_PROXY_CONF="$scratch/nginx/nodebb-proxy.conf"
    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"

    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$ROOT/overlay/usr/lib/inithooks
INITHOOKS_LOGFILE=$scratch/inithooks.log
DEF

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub nginx 'echo "nginx $*" >> "$CALLS"'
    stub chown 'echo "chown $*" >> "$CALLS"'
    stub redis-cli 'echo PONG'
    # runuser -u USER -- CMD...: drop the three leading arguments and run
    stub runuser 'echo "runuser $*" >> "$CALLS"; shift 3; exec "$@"'

    cat > "$NODEBB_DIR/nodebb" <<'NODEBB'
#!/bin/sh
echo "nodebb $*" >> "$CALLS"
[ "$1" = setup ] || exit 1
printf '%s' "$2" > ./config.json
NODEBB
    chmod +x "$NODEBB_DIR/nodebb"
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

write_conf() {
    cat > "$INITHOOKS_CONF" <<CONF
export APP_PASS=s3cret
export APP_EMAIL=admin@keellinux.org
export APP_DOMAIN=forum.keellinux.org
export APP_ADMIN_USER=admin
export APP_TRUSTED_PROXY=${1-2001:db8::13}
CONF
}

@test "the hook runs the setup and reports the url and the admin user" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NodeBB set up at https://forum.keellinux.org"* ]]
    [[ "$output" == *"admin user 'admin'"* ]]
    [ -f "$NODEBB_DIR/config.json" ]
}

@test "the hook patches config.json for the loopback and the proxy" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
assert c["bind_address"] == "::1", c
assert c["port"] == 4567, c
assert c["trust_proxy"] is True, c
assert c["url"] == "https://forum.keellinux.org", c
assert c["admin:username"] == "admin", c' "$NODEBB_DIR/config.json"
}

@test "the hook renders the proxy conf from APP_TRUSTED_PROXY" {
    write_conf 2001:db8::13
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^geo \$realip_remote_addr \$nodebb_trusted_proxy {$' "$NGINX_PROXY_CONF"
    grep -q '^    2001:db8::13 1;$' "$NGINX_PROXY_CONF"
    grep -q '^set_real_ip_from 2001:db8::13;$' "$NGINX_PROXY_CONF"
    grep -q '^real_ip_header X-Forwarded-For;$' "$NGINX_PROXY_CONF"
    grep -q '^map "\$nodebb_trusted_proxy:\$http_x_forwarded_proto" \$nodebb_scheme {$' "$NGINX_PROXY_CONF"
}

@test "the hook checks the rendered nginx configuration" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^nginx -t$' "$CALLS"
}

@test "the hook starts redis, enables nodebb and restarts nginx" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^systemctl start redis-server.service$' "$CALLS"
    grep -q '^systemctl enable --now nodebb.service$' "$CALLS"
    grep -q '^systemctl restart nginx.service$' "$CALLS"
}

@test "the hook skips the asset build when the image carries them" {
    write_conf
    mkdir -p "$NODEBB_DIR/build/public"
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- '--skip-build' "$CALLS"
}

@test "the hook builds the assets when the image does not carry them" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    ! grep -q -- '--skip-build' "$CALLS"
}

@test "the hook is idempotent: a second run changes nothing" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    first=$(cat "$NGINX_PROXY_CONF")
    cp "$NODEBB_DIR/config.json" "$scratch/config.first"
    rm -f "$CALLS"

    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already set up"* ]]
    [[ "$output" == *"nothing to do"* ]]
    [ ! -e "$CALLS" ]
    [ "$(cat "$NGINX_PROXY_CONF")" = "$first" ]
    diff -q "$NODEBB_DIR/config.json" "$scratch/config.first"
}

@test "the hook is idempotent even when the inithooks conf is gone" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    rm -f "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already set up"* ]]
}

@test "the hook refuses an APP_TRUSTED_PROXY nginx would not accept" {
    write_conf '"2001:db8::13; }"'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an address nginx accepts"* ]]
}

@test "the hook trusts nobody when APP_TRUSTED_PROXY is empty" {
    write_conf '""'
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^geo \$realip_remote_addr \$nodebb_trusted_proxy {$' "$NGINX_PROXY_CONF"
    ! grep -q '^set_real_ip_from' "$NGINX_PROXY_CONF"
}

@test "the hook falls back to the hostname when no domain is declared" {
    write_conf
    sed -i '/APP_DOMAIN/d' "$INITHOOKS_CONF"
    export FQDN=forum2.keellinux.org
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://forum2.keellinux.org"* ]]
}

@test "the hook stops when APP_PASS is missing and no terminal can be asked" {
    write_conf
    sed -i '/APP_PASS/d' "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no APP_PASS"* ]]
    [[ "$output" == *"no terminal to ask on"* ]]
}

@test "the hook runs with no inithooks conf at all and stops on the password" {
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no APP_PASS"* ]]
}

@test "the hook asks for the password on a terminal and uses the answer" {
    write_conf
    sed -i '/APP_PASS/d' "$INITHOOKS_CONF"
    # the dialog lives next to the library under INITHOOKS_PATH; point that
    # at a scratch tree whose lib is the real one and whose bin is a stub
    mkdir -p "$scratch/inithooks/bin"
    ln -s "$ROOT/overlay/usr/lib/inithooks/lib" "$scratch/inithooks/lib"
    printf '#!/bin/sh\nprintf "APP_PASS=%%s\\n" fromdialog\n' \
        > "$scratch/inithooks/bin/nodebb.py"
    chmod +x "$scratch/inithooks/bin/nodebb.py"
    sed -i "s|^INITHOOKS_PATH=.*|INITHOOKS_PATH=$scratch/inithooks|" "$INITHOOKS_DEFAULT"

    # script(1) gives the hook a terminal on stdin, which is the only way
    # into the dialog branch
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 0 ]
    grep -q fromdialog "$NODEBB_DIR/config.json"
}
