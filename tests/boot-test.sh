#!/bin/bash
# Appliance test (docs/org-plan.md section 1): the layer built by bt-layer is
# verified, pulled and assembled into an LXC rootfs, adapted for a container
# the way bt-container does, booted with a macvlan interface that gets a
# global IPv6 address by SLAAC, first booted headless from an instance spec,
# and checked over IPv6: nginx answers on port 80 and the forum on 443, and
# keel diff finds no drift. Runs as root on the build host.
#
#   tests/boot-test.sh APPLIANCE [--keep]
#
# Environment (defaults in brackets):
#   LAYERS_DIR   where bt-layer wrote the layers [/mnt/builds/layers]
#   CACHE_DIR    keel pull cache [/var/cache/keel/layers]
#   CONTAINER    LXC container name [forum]
#   LXC_LINK     host interface for macvlan [eth0]
#   BT           buildtasks checkout with patches/ [/turnkey/buildtasks-keel]
#   SPEC         instance spec to copy into the rootfs [keel/instance.example.yaml]
#   BOOT_TIMEOUT seconds to wait for the first boot [900]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLIANCE="${1:?usage: boot-test.sh APPLIANCE [--keep]}"
KEEP="${2:-}"
LAYERS_DIR="${LAYERS_DIR:-/mnt/builds/layers}"
CACHE_DIR="${CACHE_DIR:-/var/cache/keel/layers}"
CONTAINER="${CONTAINER:-forum}"
LXC_LINK="${LXC_LINK:-eth0}"
BT="${BT:-/turnkey/buildtasks-keel}"
SPEC="${SPEC:-$here/keel/instance.example.yaml}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
LXC_DIR=/var/lib/lxc/$CONTAINER
ROOTFS=$LXC_DIR/rootfs
export TERM=dumb

log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fatal() { log "FATAL: $*"; exit 1; }
timed() {
    local label=$1 started
    shift
    started=$(date +%s)
    "$@"
    log "$label: $(( $(date +%s) - started )) s"
}

[[ $(id -u) -eq 0 ]] || fatal "run as root"
for tool in keel lxc-start lxc-attach tklpatch-apply fab-chroot curl; do
    command -v "$tool" >/dev/null || fatal "$tool not found"
done

verify_layers() {
    local code=0
    keel verify --layers-dir "$LAYERS_DIR" --non-interactive || code=$?
    # 8: hash files present but no trusted key yet; 9: packages half not implemented
    [[ $code -eq 0 || $code -eq 8 || $code -eq 9 ]] || fatal "keel verify exited $code"
}

assemble() {
    if [[ -e $LXC_DIR ]]; then
        lxc-stop -n "$CONTAINER" -k 2>/dev/null || true
        rm -rf "$LXC_DIR"
    fi
    mkdir -p "$ROOTFS" "$CACHE_DIR"
    keel pull "$APPLIANCE" --source "$LAYERS_DIR" --cache-dir "$CACHE_DIR" --non-interactive
    keel assemble "$APPLIANCE" --rootfs "$ROOTFS" --cache-dir "$CACHE_DIR" --non-interactive
    du -sh "$ROOTFS" >&2
}

# what bt-container does to an ISO rootfs, applied to the assembled tree
adapt_container() {
    "$BT/bin/purge-pkgs" "$ROOTFS"
    tklpatch-apply "$ROOTFS" "$BT/patches/headless"
    tklpatch-apply "$ROOTFS" "$BT/patches/container"
    "$BT/bin/aptconf-tag" "$ROOTFS" proxmox
    "$BT/bin/build-tag" "$ROOTFS" proxmox
    # the container patch disables 30rootpass (Proxmox sets the password);
    # here the spec's root_password is what sets it
    chmod +x "$ROOTFS/usr/lib/inithooks/firstboot.d/30rootpass"
    fab-chroot "$ROOTFS" 'rm -rf /var/log/dpkg.log /var/log/apt/* /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/*.bin'
}

write_spec_and_secrets() {
    install -d -m 0755 "$ROOTFS/etc/keel"
    install -d -m 0700 "$ROOTFS/etc/keel/secrets"
    install -m 0644 "$SPEC" "$ROOTFS/etc/keel/instance.yaml"
    local name
    for name in root_password app_password; do
        if [[ ! -s "$ROOTFS/etc/keel/secrets/$name" ]]; then
            openssl rand -base64 18 > "$ROOTFS/etc/keel/secrets/$name"
            chmod 0600 "$ROOTFS/etc/keel/secrets/$name"
        fi
    done
}

write_lxc_config() {
    local hwaddr
    hwaddr="02:bc:24:11:00:$(printf '%02x' $(( $(cksum <<< "$CONTAINER" | cut -d' ' -f1) % 256 )))"
    cat > "$LXC_DIR/config" <<CONF
lxc.include = /usr/share/lxc/config/common.conf
lxc.include = /usr/share/lxc/config/nesting.conf
lxc.arch = linux64
lxc.uts.name = $CONTAINER
lxc.rootfs.path = dir:$ROOTFS

lxc.net.0.type = macvlan
lxc.net.0.macvlan.mode = bridge
lxc.net.0.link = $LXC_LINK
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.net.0.hwaddr = $hwaddr

lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.tty.max = 4
lxc.start.auto = 1
lxc.start.delay = 5
CONF
    chmod 640 "$LXC_DIR/config"
}

# the global, non temporary, non tentative IPv6 address of eth0 in the container
container_ip6() {
    lxc-attach -n "$CONTAINER" -- ip -6 -o addr show dev eth0 scope global 2>/dev/null \
        | grep -v -e temporary -e tentative | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

start_container() {
    modprobe ip6table_nat 2>/dev/null || true
    lxc-start -n "$CONTAINER"
    local n
    for (( n = 0; n < 90; n++ )); do
        IP6=$(container_ip6)
        [[ -z "$IP6" ]] || return 0
        sleep 1
    done
    fatal "no global IPv6 address on $CONTAINER after 90 s"
}

first_boot() {
    lxc-attach -n "$CONTAINER" -- keel spec apply --spec /etc/keel/instance.yaml --non-interactive
    timeout "$BOOT_TIMEOUT" lxc-attach -n "$CONTAINER" -- /usr/lib/inithooks/run
    lxc-attach -n "$CONTAINER" -- grep -c 'successfully completed' /var/log/inithooks.log >&2
    if lxc-attach -n "$CONTAINER" -- grep -E 'ERR|failed' /var/log/inithooks.log >&2; then
        log "some hooks reported an error, see the log lines above"
    fi
}

http_checks() {
    local code title
    code=$(curl -6 -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://[$IP6]/")
    log "http://[$IP6]/ -> $code"
    [[ "$code" == 307* || "$code" == 200* ]] || fatal "nginx did not answer on port 80"
    for (( n = 0; n < 60; n++ )); do
        code=$(curl -6 -k -s -o /tmp/boot-test-index.html -w '%{http_code}' "https://[$IP6]/" || true)
        [[ "$code" == 200 ]] && break
        sleep 2
    done
    [[ "$code" == 200 ]] || fatal "https://[$IP6]/ answered $code, not 200"
    title=$(grep -o '<title>[^<]*</title>' /tmp/boot-test-index.html | head -n 1)
    log "https://[$IP6]/ -> $code $title"
    [[ -n "$title" ]] || fatal "no <title> in the forum page"
}

diff_check() {
    local code=0
    lxc-attach -n "$CONTAINER" -- keel diff --spec /etc/keel/instance.yaml || code=$?
    log "keel diff exited $code"
    [[ $code -eq 0 || $code -eq 13 ]] || fatal "keel diff found drift"
}

timed verify verify_layers
timed assemble assemble
timed adapt adapt_container
write_spec_and_secrets
write_lxc_config
timed start start_container
log "container $CONTAINER has IPv6 $IP6"
timed first-boot first_boot
timed http http_checks
timed diff diff_check
if [[ "$KEEP" != "--keep" ]]; then
    lxc-stop -n "$CONTAINER"
fi
log "PASS $APPLIANCE at $IP6"
echo "$IP6"
