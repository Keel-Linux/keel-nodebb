#!/usr/bin/env bats
# conf.d/zz-check, the image check of the nodebb layer, against a scratch
# tree. Each test makes a good tree, breaks one thing and runs the check.
# The owners need root, so the tree and the check run in one fakeroot
# session: chown and stat agree inside it.

# Each test runs in its own subshell, so a change of the environment in
# a test stays in that test. The stub and tree bodies are in single quotes
# on purpose: they expand where they run.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
    CHECK="$BATS_TEST_DIRNAME/../conf.d/zz-check"
    OVERLAY="$BATS_TEST_DIRNAME/../overlay"
    T="$BATS_TEST_TMPDIR/root"
    export T OVERLAY
}

# good: the commands that make a good tree, for a fakeroot session
good='set -e
rm -rf "$T"
mkdir -p "$T/etc/systemd/system/multi-user.target.wants" "$T/var/lib/dpkg" "$T/var/www/nodebb/install" \
    "$T/var/www/nodebb/build/public" "$T/var/www/nodebb/logs" "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/emoji" \
    "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/lib" "$T/var/lib/nodebb/uploads" \
    "$T/usr/share/keel/appliances" "$T/usr/lib/systemd/system" "$T/etc/nginx/keel-default.d" "$T/etc/nginx/keel-front.d" "$T/etc/nginx/conf.d"
printf "root:x:0:0::/root:/bin/bash\nnodebb:x:120:120::/var/lib/nodebb:/usr/sbin/nologin\n" > "$T/etc/passwd"
printf "Package: keel-nodejs\nStatus: install ok installed\nVersion: 24.22.3+keel1\n\nPackage: other\nStatus: install ok installed\n" > "$T/var/lib/dpkg/status"
echo "  \"version\": \"4.16.7\"," > "$T/var/www/nodebb/install/package.json"
echo code > "$T/var/www/nodebb/app.js"
echo lib > "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/lib/index.js"
echo data > "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/emoji/table.json"
echo asset > "$T/var/www/nodebb/build/public/a.js"
: > "$T/var/www/nodebb/pidfile"
chmod -R u+rwX,go+rX,go-w "$T/var/www/nodebb"
chown -R 0:0 "$T"
chown -R 120:120 "$T/var/www/nodebb/build" "$T/var/www/nodebb/logs" "$T/var/www/nodebb/pidfile" \
    "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/emoji" "$T/var/lib/nodebb"
chown 120:120 "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build"
cp "$OVERLAY/usr/share/keel/appliances/nodebb.yaml" "$T/usr/share/keel/appliances/"
cp "$OVERLAY/usr/lib/systemd/system/nodebb.service" "$T/usr/lib/systemd/system/"
ln -s /usr/lib/systemd/system/nodebb.service "$T/etc/systemd/system/multi-user.target.wants/nodebb.service"
for f in keel-default.d/60-keel-nodebb.conf keel-front.d/60-keel-nodebb.conf conf.d/keel-nodebb.conf; do
    cp "$OVERLAY/etc/nginx/$f" "$T/etc/nginx/$f"
done
'

# check BREAK: make a good tree, run BREAK, then the check, in one session
check() {
    run fakeroot bash -c "$good
$1
KEEL_CONF_ROOT=\"\$T\" \"$CHECK\""
}

@test "a good tree passes" {
    check ':'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Redis or Apache in the image fails" {
    check 'mkdir -p "$T/usr/bin" "$T/usr/sbin"; : > "$T/usr/bin/redis-server"; : > "$T/usr/sbin/apache2"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/usr/bin/redis-server is in the image"* ]]
    [[ "$output" == *"/usr/sbin/apache2 is in the image"* ]]
}

@test "no keel-nodejs, or a keel-nodejs of another line, fails" {
    check 'printf "Package: other\nStatus: install ok installed\n" > "$T/var/lib/dpkg/status"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-nodejs is not installed"* ]]
    check 'sed -i "s/24.22.3+keel1/26.1.0+keel1/" "$T/var/lib/dpkg/status"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-nodejs 26.1.0+keel1 is not on line 24"* ]]
}

@test "another NodeBB version or a container file fails" {
    check 'echo "\"version\": \"4.10.3\"" > "$T/var/www/nodebb/install/package.json"; : > "$T/var/www/nodebb/Dockerfile"; mkdir "$T/var/www/nodebb/.docker"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"NodeBB 4.16.7 is not in /var/www/nodebb"* ]]
    [[ "$output" == *"/var/www/nodebb/Dockerfile is in the image"* ]]
    [[ "$output" == *"/var/www/nodebb/.docker is in the image"* ]]
}

@test "a file that group or others can write fails" {
    check 'chmod 0664 "$T/var/www/nodebb/app.js"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/www/nodebb/app.js can be written by group or others"* ]]
}

@test "no user nodebb, or a nodebb with a shell, fails" {
    check 'sed -i "/^nodebb:/d" "$T/etc/passwd"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodebb is not a system user"* ]]
    check 'sed -i "s|^nodebb:.*|nodebb:x:120:120::/var/lib/nodebb:/bin/bash|" "$T/etc/passwd"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodebb has a shell"* ]]
}

@test "nodebb owning a file of the code fails" {
    check 'chown 120:120 "$T/var/www/nodebb/app.js" "$T/var/www/nodebb/node_modules/nodebb-plugin-emoji/build/lib/index.js"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodebb owns /var/www/nodebb/app.js"* ]]
    [[ "$output" == *"nodebb owns /var/www/nodebb/node_modules/nodebb-plugin-emoji/build/lib/index.js"* ]]
}

@test "a path that NodeBB writes and does not own, or that is not there, fails" {
    check 'chown 0:0 "$T/var/www/nodebb/logs"; rm "$T/var/www/nodebb/pidfile"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/www/nodebb/logs is not owned by nodebb"* ]]
    [[ "$output" == *"/var/www/nodebb/pidfile is not in the image"* ]]
}

@test "config.json, the ready mark or an upload in the image fails" {
    check 'echo "{}" > "$T/var/www/nodebb/config.json"; mkdir -p "$T/var/lib/keel-nodebb"; : > "$T/var/lib/keel-nodebb/ready"; : > "$T/var/lib/nodebb/uploads/x.png"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"config.json is in the image"* ]]
    [[ "$output" == *"/var/lib/keel-nodebb/ready is in the image"* ]]
    [[ "$output" == *"/var/lib/nodebb/uploads is not empty"* ]]
}

@test "a unit that is not enabled or does not run serve.py fails" {
    check 'rm "$T/etc/systemd/system/multi-user.target.wants/nodebb.service"; sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/node loader.js|" "$T/usr/lib/systemd/system/nodebb.service"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodebb.service is not enabled"* ]]
    [[ "$output" == *"does not run usr/lib/keel-nodebb/serve.py"* ]]
}

@test "a missing route or the own site of the old layer fails" {
    check 'rm "$T/etc/nginx/keel-front.d/60-keel-nodebb.conf"; mkdir -p "$T/etc/nginx/sites-available"; : > "$T/etc/nginx/sites-available/nodebb"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/etc/nginx/keel-front.d/60-keel-nodebb.conf is not in the image"* ]]
    [[ "$output" == *"own Nginx site of the old layer"* ]]
}

@test "any part of the check page of lnpp fails" {
    check 'mkdir -p "$T/usr/lib/inithooks/firstboot.d" "$T/usr/share/keel-lnpp"; : > "$T/usr/lib/inithooks/firstboot.d/40lnpp-check"; echo "keel-check:x:121:121::/:/usr/sbin/nologin" >> "$T/etc/passwd"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"40lnpp-check is in the image"* ]]
    [[ "$output" == *"/usr/share/keel-lnpp is in the image"* ]]
    [[ "$output" == *"keel-check is a user of the image"* ]]
}

@test "no manifest, a manifest that cannot be read, or a replicated path that is wrong fails" {
    check 'rm "$T/usr/share/keel/appliances/nodebb.yaml"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodebb.yaml is not in the image"* ]]
    check 'echo "state: [unclosed" > "$T/usr/share/keel/appliances/nodebb.yaml"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"state.replicate cannot be read"* ]]
    check 'chown 0:0 "$T/var/lib/nodebb/uploads"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/lib/nodebb/uploads is not owned by nodebb"* ]]
    check 'rmdir "$T/var/lib/nodebb/uploads"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/lib/nodebb/uploads is not a directory of the image"* ]]
}
