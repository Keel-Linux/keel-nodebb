#!/bin/bash
# Boot test of this appliance (org-plan section 1), modelled on the one in
# keel-core: assemble the published layer chain into an LXC rootfs, boot it
# headless from tests/instance.yaml, wait for the first boot to finish, check
# that the forum answers over IPv6, and check that keel diff reports no drift
# between the spec and the machine.
#
# Called by the reusable workflow test-appliance.yml after keel pull and
# keel verify; runnable by hand as root on any host with LXC, see
# tests/README.md. It builds nothing: the layers come from the mirror or from
# a directory bt-layer wrote, so the test needs no fab, deck or buildtasks.
# The logic lives in tests/lib/boot-test-lib.sh and is unit tested; this file
# is the thin main that touches the system.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

container_dir=$BT_LXC_PATH/$BT_NAME
log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() { "lxc-$1" -P "$BT_LXC_PATH" -n "$BT_NAME" "${@:2}"; }

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -r "$BT_ROOTFS/var/log/inithooks.log" ]; then
        log "last lines of the container's inithooks log:"
        tail -n 40 "$BT_ROOTFS/var/log/inithooks.log"
    fi
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping $BT_NAME under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n $BT_NAME"
        return
    fi
    lxc stop -k >/dev/null 2>&1 || true
    rm -rf "$container_dir"
}
trap cleanup EXIT

# 1. Assemble the chain from the layers the build host published.
log "assembling $BT_APPLIANCE from $BT_LAYERS_DIR into $BT_ROOTFS"
lxc stop -k >/dev/null 2>&1 || true
rm -rf "$container_dir"
mkdir -p "$BT_ROOTFS"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive
keel assemble "$BT_APPLIANCE" --rootfs "$BT_ROOTFS" --cache-dir "$BT_CACHE_DIR" --non-interactive

# 2. The container marker, the instance spec, the secrets it references and
#    the conf the first boot hooks read. The marker under
#    /var/lib/turnkey-info is what bt-container writes and what inspect reads
#    to call the machine a container (managed_by: host); the conf is what
#    makes the first boot headless, and without it 30rootpass and 40nodebb
#    wait on a dialog forever.
log "installing the spec, the secrets and the conf into $BT_ROOTFS"
install -D -m 0644 /dev/null "$BT_ROOTFS/var/lib/turnkey-info/inithooks.service/lxc"
install -d -m 0700 "$BT_ROOTFS/etc/keel/secrets"
for target in $(bt_secret_targets "$BT_ROOTFS"); do
    bt_random_password > "$target"
    chmod 0600 "$target"
done
for target in $(bt_spec_targets "$BT_ROOTFS"); do
    install -D -m 0600 "$BT_SPEC" "$target"
done
bt_spec_in_rootfs "$BT_SPEC" "$BT_ROOTFS" > "$container_dir/instance-host.yaml"
keel spec apply --spec "$container_dir/instance-host.yaml" \
    --conf "$BT_ROOTFS/etc/inithooks.conf" --non-interactive

# 3. Boot.
bt_lxc_config "$BT_NAME" "$BT_ROOTFS" "$BT_BRIDGE" > "$container_dir/config"
log "starting $BT_NAME on bridge $BT_BRIDGE"
lxc start -d

# 4. A global IPv6 address from the bridge.
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $BT_NAME" \
    bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH" > /dev/null
addr=$(bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH")
log "container address $addr"

# 5. First boot finished: 98finalize has cleared RUN_FIRSTBOOT and the
#    machine answers, on the console (confconsole's usage screen) or on SSH.
#    The answer alone is not enough: sshd is up long before the hooks are
#    done, so the flag is what says the first boot ended.
usage_screen() {
    lxc attach -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$addr" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    bt_firstboot_done_in "$BT_ROOTFS/etc/default/inithooks" || return 1
    usage_screen || ssh_answers
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of $BT_NAME to finish" \
    first_boot_done
log "first boot finished; ssh root@$addr"

# 6. The forum answers over IPv6: nginx redirects port 80 to https, and the
#    NodeBB page comes back on 443 with a title. NodeBB takes a moment after
#    its unit is started, so the page is polled.
redirect=$(curl -6 -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://[$addr]/")
log "http://[$addr]/ answered $redirect"
# shellcheck disable=SC2086  # two fields, split on purpose
bt_redirects_to_https $redirect \
    || { echo "boot-test: nginx did not redirect port 80 to https" >&2; exit 1; }

page=$container_dir/index.html
code=""
forum_answers() {
    code=$(curl -6 -k -s -o "$page" -w '%{http_code}' "https://[$addr]/" || true)
    [ "$code" = 200 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the forum on https://[$addr]/" forum_answers
bt_http_verdict "$code" "$(bt_page_title "$page")"

# 7. No drift between the declared spec and the booted root.
set +e
keel diff --root "$BT_ROOTFS" --spec "$BT_SPEC"
code=$?
set -e
bt_diff_verdict "$code"
log "$BT_APPLIANCE boot test passed"
