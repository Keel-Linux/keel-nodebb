#!/usr/bin/env bats
# Unit tests for overlay/usr/lib/inithooks/lib/nodebb.sh (decision 0004):
# scratch directories for every path, a PATH stub for redis-cli, python3
# real (it only encodes and decodes JSON here).

setup() {
    LIB="$BATS_TEST_DIRNAME/../overlay/usr/lib/inithooks/lib/nodebb.sh"
    # shellcheck source=../overlay/usr/lib/inithooks/lib/nodebb.sh
    source "$LIB"
    scratch="$BATS_TEST_TMPDIR/nodebb"
    mkdir -p "$scratch"
}

@test "needs_setup is true without config.json and false with it" {
    nodebb_needs_setup "$scratch"
    touch "$scratch/config.json"
    ! nodebb_needs_setup "$scratch"
}

@test "first_value skips empty values and the DEFAULT placeholder" {
    run nodebb_first_value "" DEFAULT default forum.example.org other
    [ "$status" -eq 0 ]
    [ "$output" = "forum.example.org" ]
}

@test "first_value fails when nothing usable is given" {
    run nodebb_first_value "" DEFAULT
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "domain prefers APP_DOMAIN, then FQDN, then the hostname" {
    [ "$(nodebb_domain forum.example.org host.example.org host)" = "forum.example.org" ]
    [ "$(nodebb_domain DEFAULT host.example.org host)" = "host.example.org" ]
    [ "$(nodebb_domain "" "" host)" = "host" ]
}

@test "url is https on the domain and fails on an empty domain" {
    [ "$(nodebb_url forum.example.org)" = "https://forum.example.org" ]
    run nodebb_url ""
    [ "$status" -eq 1 ]
}

@test "email falls back to admin at the domain" {
    [ "$(nodebb_email me@example.org forum.example.org)" = "me@example.org" ]
    [ "$(nodebb_email "" forum.example.org)" = "admin@forum.example.org" ]
}

@test "admin_user falls back to admin" {
    [ "$(nodebb_admin_user marcos)" = "marcos" ]
    [ "$(nodebb_admin_user "")" = "admin" ]
}

@test "missing_values names APP_PASS only when it is empty" {
    [ "$(nodebb_missing_values "")" = "APP_PASS" ]
    [ -z "$(nodebb_missing_values secret)" ]
}

@test "setup_json encodes every value, a password with quotes included" {
    run nodebb_setup_json https://forum.example.org admin 'p"a$s' admin@example.org
    [ "$status" -eq 0 ]
    python3 -c 'import json, sys
c = json.loads(sys.argv[1])
assert c["url"] == "https://forum.example.org", c
assert c["database"] == "redis" and c["redis:host"] == "127.0.0.1", c
assert c["redis:port"] == 6379 and c["redis:database"] == 0, c
assert c["admin:username"] == "admin" and c["admin:email"] == "admin@example.org", c
assert c["admin:password"] == c["admin:password:confirm"] == "p\"a$s", c' "$output"
}

@test "setup_json fails when a value is missing" {
    run nodebb_setup_json https://forum.example.org admin "" admin@example.org
    [ "$status" -eq 1 ]
}

@test "setup_args skips the build only when the assets exist" {
    [ -z "$(nodebb_setup_args "$scratch")" ]
    mkdir -p "$scratch/build/public"
    [ "$(nodebb_setup_args "$scratch")" = "--skip-build" ]
}

@test "config_patch adds bind_address, port and trust_proxy and keeps the rest" {
    echo '{"url": "https://forum.example.org", "secret": "s"}' > "$scratch/config.json"
    nodebb_config_patch "$scratch/config.json" ::1 4567
    python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
assert c == {"url": "https://forum.example.org", "secret": "s",
             "bind_address": "::1", "port": 4567, "trust_proxy": True}, c' "$scratch/config.json"
}

@test "config_patch fails when the file is absent" {
    run nodebb_config_patch "$scratch/none.json" ::1 4567
    [ "$status" -eq 1 ]
}

@test "wait_redis returns as soon as the stub answers PONG" {
    mkdir -p "$scratch/bin"
    printf '#!/bin/sh\ncount=$(cat %s/count 2>/dev/null || echo 0)\ncount=$((count + 1))\necho $count > %s/count\n[ $count -ge 2 ] && echo PONG || echo error\n' \
        "$scratch" "$scratch" > "$scratch/bin/redis-cli"
    chmod +x "$scratch/bin/redis-cli"
    nodebb_wait_redis "$scratch/bin/redis-cli" 5
    [ "$(cat "$scratch/count")" = "2" ]
}

@test "wait_redis fails after the given number of tries" {
    mkdir -p "$scratch/bin"
    printf '#!/bin/sh\necho error\n' > "$scratch/bin/redis-cli"
    chmod +x "$scratch/bin/redis-cli"
    run nodebb_wait_redis "$scratch/bin/redis-cli" 1
    [ "$status" -eq 1 ]
}

@test "valid_proxy accepts IPv6 and IPv4 with or without a prefix and rejects junk" {
    nodebb_valid_proxy 2001:db8::13
    nodebb_valid_proxy 2001:db8::/64
    nodebb_valid_proxy 192.0.2.7
    ! nodebb_valid_proxy "2001:db8::13; }"
    ! nodebb_valid_proxy "hello"
}

@test "proxy_conf with an address trusts it in geo and real_ip" {
    run nodebb_proxy_conf 2001:db8::13
    [ "$status" -eq 0 ]
    grep -q '^    2001:db8::13 1;$' <<< "$output"
    grep -q '^set_real_ip_from 2001:db8::13;$' <<< "$output"
    grep -q '"1:https" https;' <<< "$output"
}

@test "proxy_conf without an address trusts nobody" {
    run nodebb_proxy_conf ""
    [ "$status" -eq 0 ]
    ! grep -q ' 1;$' <<< "$output"
    ! grep -q set_real_ip_from <<< "$output"
    grep -q 'default 0;' <<< "$output"
}

@test "proxy_conf rejects an address nginx would not accept" {
    run nodebb_proxy_conf "2001:db8::13; }"
    [ "$status" -eq 1 ]
}
