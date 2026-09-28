#!/usr/bin/env bats
# The nginx files the appliance ships in its overlay, and their agreement
# with what lib/nodebb.sh renders at first boot (decision 0004: the shipped
# default and the rendered file must not drift apart, since the rendered one
# replaces the other and only the rendered one is exercised in production).

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$ROOT/overlay/usr/lib/inithooks/lib/nodebb.sh"
    SITE="$ROOT/overlay/etc/nginx/sites-available/nodebb"
    INCLUDE="$ROOT/overlay/etc/nginx/include/nodebb-proxy"
    DEFAULT_CONF="$ROOT/overlay/etc/nginx/conf.d/nodebb-proxy.conf"
    # shellcheck source=../overlay/usr/lib/inithooks/lib/nodebb.sh
    source "$LIB"
}

@test "the shipped conf.d default trusts nobody" {
    grep -q '^    default 0;$' "$DEFAULT_CONF"
    run ! grep -q ' 1;$' "$DEFAULT_CONF"
    run ! grep -q '^set_real_ip_from' "$DEFAULT_CONF"
}

@test "the shipped conf.d default uses the same geo variable as the rendered file" {
    grep -q '^geo \$realip_remote_addr \$nodebb_trusted_proxy {$' "$DEFAULT_CONF"
    nodebb_proxy_conf "" | grep -q '^geo \$realip_remote_addr \$nodebb_trusted_proxy {$'
}

@test "the shipped conf.d default never matches geo on remote_addr" {
    run ! grep -q '^geo \$remote_addr' "$DEFAULT_CONF"
    run ! grep -q '^geo \$nodebb_trusted_proxy' "$DEFAULT_CONF"
}

@test "the shipped conf.d default carries the same map as the rendered file" {
    grep -q '^map "\$nodebb_trusted_proxy:\$http_x_forwarded_proto" \$nodebb_scheme {$' "$DEFAULT_CONF"
    grep -q '^    "1:https" https;$' "$DEFAULT_CONF"
    grep -q '^    default \$scheme;$' "$DEFAULT_CONF"
}

@test "the site file redirects port 80 unless the scheme is the trusted https" {
    grep -q 'if (\$nodebb_scheme != https)' "$SITE"
    grep -q 'return 307 https://\$host\$request_uri;' "$SITE"
}

@test "the site file keeps the ACME path on port 80" {
    grep -q 'location \^~ /.well-known/acme-challenge/' "$SITE"
}

@test "the site file listens IPv6 first on both ports" {
    grep -q '^    listen \[::\]:80 default_server;$' "$SITE"
    grep -q '^    listen \[::\]:443 ssl default_server;$' "$SITE"
    [ "$(grep -c 'listen \[::\]' "$SITE")" -eq 2 ]
}

@test "the site file proxies to NodeBB on the IPv6 loopback" {
    grep -q '^    server \[::1\]:4567;$' "$SITE"
}

@test "the site file includes the shared proxy directives in both servers" {
    [ "$(grep -c 'include /etc/nginx/include/nodebb-proxy;' "$SITE")" -eq 2 ]
}

@test "the shared proxy directives forward the trusted scheme, not the raw one" {
    grep -q '^proxy_set_header X-Forwarded-Proto \$nodebb_scheme;$' "$INCLUDE"
    run ! grep -q 'X-Forwarded-Proto \$scheme;' "$INCLUDE"
}

@test "the shared proxy directives carry the websocket upgrade headers" {
    grep -q '^proxy_set_header Upgrade \$http_upgrade;$' "$INCLUDE"
    grep -q '^proxy_set_header Connection "upgrade";$' "$INCLUDE"
    grep -q '^proxy_http_version 1.1;$' "$INCLUDE"
}

@test "the shared proxy directives keep the original Host" {
    grep -q '^proxy_set_header Host \$host;$' "$INCLUDE"
}
