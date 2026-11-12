#!/usr/bin/env bats
# The files of the layer that no program runs in a test: the plan, the
# build script, the unit, the routes and the manifest (handbook note 0082).
# conf.d/main needs a chroot and the network; the real-node run of
# 2026-11-11 (CT 9385, BR1) ran it, and its evidence is in the handbook.

# The patterns are literal Nginx text in single quotes on purpose.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
    R="$BATS_TEST_DIRNAME/.."
    O="$R/overlay"
}

@test "the plan installs the package of line 24 and no Redis, no Debian nodejs" {
    grep -qx 'keel-nodejs-24' "$R/plan/main"
    grep -q '"keel-nodejs-$NODE_LINE"' "$R/conf.d/main"
    grep -qx 'NODE_LINE=24' "$R/conf.d/main"
    run grep -E '^(redis|nodejs|npm)' "$R/plan/main"
    [ "$status" -eq 1 ]
}

@test "the build pins NodeBB 4.16.7 by sha256 and installs from the lock file" {
    grep -qx 'NODEBB_VERSION=4.16.7' "$R/conf.d/main"
    grep -qE '^NODEBB_SHA256=[0-9a-f]{64}$' "$R/conf.d/main"
    grep -q 'sha256sum --check --strict' "$R/conf.d/main"
    grep -q 'npm ci --omit=dev' "$R/conf.d/main"
    run grep -E 'npm (install|i) ' "$R/conf.d/main"
    [ "$status" -eq 1 ]
}

@test "the build removes the test suite of secure-keys, which holds a private key" {
    grep -q '^test -f node_modules/secure-keys/test/test.secret.key$' "$R/conf.d/main"
    grep -q '^rm -rf node_modules/secure-keys/test$' "$R/conf.d/main"
}

@test "the lock file is of NodeBB 4.16.7, with no git source" {
    lock="$O/usr/share/keel-nodebb/package-lock.json"
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); r = d["packages"][""]; assert r["name"] == "nodebb" and r["version"] == "4.16.7"; assert not [k for k, v in d["packages"].items() if v.get("resolved", "").startswith(("git", "github:"))]' "$lock"
}

@test "the build hides the scratch passwords from the trace" {
    run awk '/^set \+x$/ { off = 1 } /APP_PASS=|DB_PASS=/ && !off { print } /^set -x$/ { off = 0 }' "$R/conf.d/main"
    [ -z "$output" ]
}

@test "the unit runs serve.py as nodebb in a read-only tree with the paths of note 0082" {
    u="$O/usr/lib/systemd/system/nodebb.service"
    grep -qx 'User=nodebb' "$u"
    grep -qx 'ProtectSystem=strict' "$u"
    grep -qx 'ReadWritePaths=/var/lib/nodebb /var/www/nodebb/build /var/www/nodebb/logs /var/www/nodebb/pidfile' "$u"
    grep -qx 'ReadWritePaths=/var/www/nodebb/node_modules/nodebb-plugin-emoji/build' "$u"
    grep -qx 'RuntimeDirectory=keel-nodebb' "$u"
    grep -qx 'enable nodebb.service' "$O/usr/lib/systemd/system-preset/20-keel-nodebb.preset"
}

@test "a change of the Node.js binary restarts NodeBB through a path unit of the layer" {
    p="$O/usr/lib/systemd/system/nodebb-nodejs.path"
    grep -qx 'PathChanged=/usr/lib/keel-nodejs/bin/node' "$p"
    grep -qx 'Unit=nodebb-nodejs.service' "$p"
    grep -qx 'WantedBy=paths.target' "$p"
    grep -qx 'ExecStart=/usr/bin/systemctl try-restart nodebb.service' "$O/usr/lib/systemd/system/nodebb-nodejs.service"
    grep -qx 'enable nodebb-nodejs.path' "$O/usr/lib/systemd/system-preset/20-keel-nodebb.preset"
    grep -qx 'systemctl enable nodebb-nodejs.path' "$R/conf.d/main"
}

@test "the routes go to 127.0.0.1:4567, show the replica notice, and pass socket.io" {
    r="$O/etc/nginx/keel-default.d/60-keel-nodebb.conf"
    [ "$(grep -c 'proxy_pass http://127.0.0.1:4567;' "$r")" -eq 3 ]
    [ "$(grep -c 'if (-f /run/keel-nodebb/replica)' "$r")" -eq 3 ]
    grep -q 'location ^~ /socket.io/' "$r"
    grep -q 'proxy_set_header Upgrade $http_upgrade;' "$r"
    grep -q 'proxy_set_header Connection $keel_nodebb_connection;' "$r"
    grep -q 'This node is the replica of a cloud pair.' "$O/usr/share/keel-nodebb/www/keel-nodebb-replica.html"
    # only the upload routes take a large body
    [ "$(grep -c 'client_max_body_size' "$r")" -eq 1 ]
}

@test "the manifest is on lnpp, replicates the uploads, and declares the shared secret" {
    m="$O/usr/share/keel/appliances/nodebb.yaml"
    python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["base"] == "lnpp"; assert d["state"]["replicate"] == ["/var/lib/nodebb/uploads"]; s = d["secrets"][0]; assert s["name"] == "nodebb_secret" and s["shared"] is True and s["generate"] == "required"; assert "processes" not in d' "$m"
}

@test "the upload path of nodebb.py is the replicated path" {
    grep -qx 'UPLOADS = "/var/lib/nodebb/uploads"' "$O/usr/lib/inithooks/bin/nodebb.py"
}

@test "nothing of the old layer and no container file is left" {
    # the only apt file of the layer is the pin of the Node.js line: no
    # source entry and no pin of an archive (the build time apt block is gone)
    [ "$(cd "$R/overlay/etc/apt" && find . -type f)" = ./preferences.d/keel-nodebb-nodejs ]
    for p in overlay/etc/nginx/sites-available bin/keel-archive-check conf.d/zz-project-packages \
            stacks overlay/usr/lib/inithooks/firstboot.d/40nodebb overlay/etc/systemd/system/nodebb.service; do
        [ ! -e "$R/$p" ]
    done
    # conf.d/ removes and checks the container files of upstream by name
    run git -C "$R" grep -n -i -E 'docker|podman|^[[:space:]]*container:' -- \
        ':!tests/layer.bats' ':!tests/image-check.bats' ':!conf.d/*' ':!*.md' ':!README.rst' ':!changelog'
    [ "$status" -eq 1 ]
}

@test "an apt pin keeps the Node.js line of the plan, and blocks every other line" {
    f="$O/etc/apt/preferences.d/keel-nodebb-nodejs"
    # the record of the line of the plan comes first: apt takes the first
    # record that matches a package
    [ "$(grep -m1 '^Package:' "$f")" = "Package: keel-nodejs-24" ]
    [ "$(awk '/^Package: keel-nodejs-24$/ { p = 1; next } p && /^Pin:/ { print; exit }' "$f")" = "Pin: version 24.*" ]
    [ "$(awk '/^Package: keel-nodejs-24$/ { p = 1; next } p && /^Pin-Priority:/ { print $2; exit }' "$f")" = 500 ]
    grep -qx 'Package: keel-nodejs keel-nodejs-\*' "$f"
    [ "$(awk '/^Package: keel-nodejs keel-nodejs-\*$/ { p = 1; next } p && /^Pin-Priority:/ { print $2; exit }' "$f")" = -1 ]
    # the line of the pin is the line of the plan
    grep -qx "keel-nodejs-$(sed -n 's/^NODE_LINE=//p' "$R/conf.d/main")" "$R/plan/main"
}
