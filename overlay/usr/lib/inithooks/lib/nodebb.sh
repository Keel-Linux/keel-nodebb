#!/bin/bash
# Logic behind firstboot.d/40nodebb. Meant to be sourced. Every function
# reads its inputs from its arguments, prints its result on stdout and
# returns non-zero instead of exiting, so the hook decides what is fatal and
# a test can exercise every branch without touching the system.

NODEBB_DIR="${NODEBB_DIR:-/var/www/nodebb}"
NODEBB_USER="${NODEBB_USER:-nodebb}"
NODEBB_BIND="${NODEBB_BIND:-::1}"
NODEBB_PORT="${NODEBB_PORT:-4567}"
NODEBB_REDIS_HOST="${NODEBB_REDIS_HOST:-127.0.0.1}"

# nodebb_needs_setup DIR: true while DIR has no config.json (setup not run)
nodebb_needs_setup() {
    [[ ! -e "$1/config.json" ]]
}

# nodebb_first_value VALUE...: the first argument that is set and is not the
# inithooks placeholder DEFAULT; fails when there is none
nodebb_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            echo "$value"
            return 0
        fi
    done
    return 1
}

# nodebb_domain APP_DOMAIN FQDN HOSTNAME: the domain the forum is served on
nodebb_domain() {
    nodebb_first_value "$1" "$2" "$3"
}

# nodebb_url DOMAIN: the public URL NodeBB is configured with (https only)
nodebb_url() {
    local domain=$1
    [[ -n "$domain" ]] || return 1
    echo "https://${domain}"
}

# nodebb_email APP_EMAIL DOMAIN: the admin email, admin@DOMAIN when absent
nodebb_email() {
    nodebb_first_value "$1" "admin@$2"
}

# nodebb_admin_user APP_ADMIN_USER: the admin login, admin when absent
nodebb_admin_user() {
    nodebb_first_value "$1" admin
}

# nodebb_missing_values PASS: the names of the values that need a prompt
nodebb_missing_values() {
    local pass=$1
    [[ -n "$pass" ]] || echo APP_PASS
    return 0
}

# nodebb_setup_json URL USER PASS EMAIL: the initial config for
# "./nodebb setup", JSON encoded by python3 so any password survives
nodebb_setup_json() {
    local url=$1 user=$2 pass=$3 email=$4
    [[ -n "$url" && -n "$user" && -n "$pass" && -n "$email" ]] || return 1
    # one line on purpose: kcov counts a continued command on its first line only
    python3 -c 'import json, sys; a = sys.argv; print(json.dumps({"url": a[1], "database": "redis", "redis:host": a[5], "redis:port": 6379, "redis:password": "", "redis:database": 0, "admin:username": a[2], "admin:password": a[3], "admin:password:confirm": a[3], "admin:email": a[4]}))' "$url" "$user" "$pass" "$email" "$NODEBB_REDIS_HOST"
}

# nodebb_setup_args DIR: --skip-build when the image already carries the
# compiled assets (conf.d/main builds them), nothing otherwise
nodebb_setup_args() {
    if [[ -d "$1/build/public" ]]; then
        echo "--skip-build"
    fi
    return 0
}

# nodebb_config_patch FILE BIND PORT: bind NodeBB to the loopback behind
# nginx and trust the proxy headers; setup does not take these keys
nodebb_config_patch() {
    local file=$1 bind=$2 port=$3
    [[ -f "$file" ]] || return 1
    python3 -c 'import json, sys; p, b, n = sys.argv[1:4]; c = json.load(open(p)); c.update({"bind_address": b, "port": int(n), "trust_proxy": True}); open(p, "w").write(json.dumps(c, indent=4) + "\n")' "$file" "$bind" "$port"
}

# nodebb_wait_redis CLI TRIES: poll "CLI ping" until it answers PONG
nodebb_wait_redis() {
    local cli=$1 tries=$2 n
    for (( n = 0; n < tries; n++ )); do
        if [[ "$("$cli" ping 2>/dev/null)" == PONG ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# nodebb_valid_proxy ADDR: an IPv6 or IPv4 address, optionally with a prefix
# length, as nginx geo and set_real_ip_from accept it
nodebb_valid_proxy() {
    [[ "$1" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]
}

# nodebb_proxy_conf ADDR: the nginx conf.d file that trusts X-Forwarded-Proto
# and X-Forwarded-For from ADDR; with no ADDR the file trusts nobody. Fails
# on an address nginx would reject.
nodebb_proxy_conf() {
    local addr=$1 trusted="" realip=""
    if [[ -n "$addr" ]]; then
        nodebb_valid_proxy "$addr" || return 1
        trusted="    $addr 1;"$'\n'
        realip=$'\n'"set_real_ip_from $addr;"$'\n'"real_ip_header X-Forwarded-For;"$'\n'
    fi
    cat <<CONF
# Which upstream proxy may set X-Forwarded-Proto for the NodeBB site.
# Written at first boot by firstboot.d/40nodebb from APP_TRUSTED_PROXY
# (app.options.trusted_proxy in the instance spec).
geo \$nodebb_trusted_proxy {
    default 0;
${trusted}}

map "\$nodebb_trusted_proxy:\$http_x_forwarded_proto" \$nodebb_scheme {
    "1:https" https;
    default \$scheme;
}
${realip}
CONF
}
