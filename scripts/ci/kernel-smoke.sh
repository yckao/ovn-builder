#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C TZ=UTC

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if (($# != 4)); then
    die "usage: kernel-smoke.sh EXPECTED_UBUNTU EXPECTED_UNAME OVS_BUNDLE OVN_BUNDLE"
fi

expected_ubuntu=$1
expected_uname=$2
ovs_bundle=$3
ovn_bundle=$4
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == "$expected_ubuntu" ]] || {
    die "expected Ubuntu $expected_ubuntu, got ${ID:-unknown} ${VERSION_ID:-unknown}"
}
actual_uname=$(uname -r)
[[ $actual_uname == "$expected_uname" ]] || {
    die "expected kernel $expected_uname, got $actual_uname"
}
[[ $(ps -p 1 -o comm= | tr -d '[:space:]') == systemd ]] || {
    die "the exact-kernel runner must be booted with systemd as PID 1"
}
command -v timeout >/dev/null || die "timeout is required"
sudo -n true || die "passwordless sudo is required on the exact-kernel runner"

"$root/scripts/bundle/verify.sh" "$ovs_bundle"
"$root/scripts/bundle/verify.sh" "$ovn_bundle"

host_arch=$(dpkg --print-architecture)
jq -e --arg ubuntu "$expected_ubuntu" --arg arch "$host_arch" '
    .product == "ovs" and
    .target.ubuntu_version == $ubuntu and
    .target.architecture == $arch and
    all(.packages[]; .component == "ovs")
' "$ovs_bundle/manifest.v1.json" >/dev/null || {
    die "standalone OVS bundle does not match the runner target"
}
jq -e --arg ubuntu "$expected_ubuntu" --arg arch "$host_arch" '
    .product == "ovn" and
    .target.ubuntu_version == $ubuntu and
    .target.architecture == $arch and
    any(.packages[]; .component == "ovn")
' "$ovn_bundle/manifest.v1.json" >/dev/null || {
    die "combined OVN bundle does not match the runner target"
}

expected_kernel_package_version=$(jq -er --arg ubuntu "$expected_ubuntu" '
    .ubuntu[$ubuntu].kernel.package_version |
    select(type == "string" and length > 0)
' "$ovs_bundle/metadata/source-lock.json") || {
    die "the release lock has no kernel package version for Ubuntu $expected_ubuntu"
}
mapfile -t kernel_packages < <(jq -r --arg ubuntu "$expected_ubuntu" '
    .ubuntu[$ubuntu].kernel.packages[] |
    select(test("^linux-(image|modules|modules-extra)-"))
' "$ovs_bundle/metadata/source-lock.json")
((${#kernel_packages[@]} == 3)) || {
    die "the release lock must identify image, modules, and modules-extra kernel packages"
}
for kernel_package in "${kernel_packages[@]}"; do
    installed_kernel_version=$(dpkg-query -W -f='${Version}' "$kernel_package" 2>/dev/null) || {
        die "locked kernel package is not installed: $kernel_package"
    }
    [[ $installed_kernel_version == "$expected_kernel_package_version" ]] || {
        die "$kernel_package is $installed_kernel_version, expected $expected_kernel_package_version"
    }
done

declare -a ovs_packages=()
declare -a ovn_packages=()

package_from_bundle() {
    local bundle=$1
    local component=$2
    local package=$3
    local output_name=$4
    local -a files=()

    mapfile -t files < <(
        jq -r --arg component "$component" --arg package "$package" '
            .packages[] |
            select(.component == $component and .package == $package) |
            .file
        ' "$bundle/manifest.v1.json"
    )
    ((${#files[@]} == 1)) || die "expected one $component/$package DEB in $bundle"
    [[ -f $bundle/${files[0]} && ! -L $bundle/${files[0]} ]] || {
        die "missing regular DEB for $component/$package in $bundle"
    }
    printf -v "$output_name" '%s' "$bundle/${files[0]}"
}

for package in openvswitch-common openvswitch-switch python3-openvswitch; do
    deb=
    package_from_bundle "$ovs_bundle" ovs "$package" deb
    ovs_packages+=("$deb")
done
for package in ovn-common ovn-host ovn-central; do
    deb=
    package_from_bundle "$ovn_bundle" ovn "$package" deb
    ovn_packages+=("$deb")
done

run_root() {
    local limit=$1
    shift
    sudo -n timeout --kill-after=10s "$limit" "$@"
}

service_active() {
    run_root 5s systemctl is-active --quiet "$1"
}

wait_for() {
    local description=$1
    local limit=$2
    shift 2
    local deadline=$((SECONDS + limit))

    while ((SECONDS < deadline)); do
        if "$@"; then
            return 0
        fi
        sleep 1
    done
    die "timed out after ${limit}s waiting for $description"
}

tmp=$(mktemp -d)
run_token=${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$
run_token=${run_token//[^A-Za-z0-9_.-]/-}
test_bridge=br-ovn-ci
binding_iface=ovn-ci0
logical_switch=ci-ls-$run_token
logical_port=ci-lsp-$run_token
chassis=

policy_path=/usr/sbin/policy-rc.d
policy_backup=$tmp/policy-rc.d.original
policy_had_file=false
policy_installed=false
ovs_was_active=false
central_was_active=false
controller_was_active=false
central_started=false
controller_started=false
logical_created=false
external_ids_set=false
test_bridge_created=false
br_int_owned=false

restore_policy() {
    [[ $policy_installed == true ]] || return 0
    if [[ $policy_had_file == true ]]; then
        sudo -n cp -a -- "$policy_backup" "$policy_path"
    else
        sudo -n rm -f -- "$policy_path"
    fi
    policy_installed=false
}

diagnostics() {
    printf '%s\n' '--- exact-kernel failure diagnostics ---' >&2
    run_root 10s systemctl --no-pager --full status \
        openvswitch-switch.service ovn-central.service ovn-host.service >&2 || true
    run_root 10s journalctl --no-pager -n 120 \
        -u openvswitch-switch.service -u ovn-central.service -u ovn-host.service >&2 || true
    run_root 5s ovs-vsctl --timeout=3 show >&2 || true
    run_root 5s ovn-nbctl --timeout=3 show >&2 || true
    run_root 5s ovn-sbctl --timeout=3 show >&2 || true
}

cleanup() {
    local rc=$?
    local cleanup_failed=false
    local stop_central=false
    local stop_controller=false
    trap - EXIT
    set +e

    cleanup_step() {
        local description=$1
        shift
        if ! "$@" >/dev/null 2>&1; then
            printf 'cleanup failed: %s\n' "$description" >&2
            cleanup_failed=true
        fi
    }

    cleanup_step "restore $policy_path" restore_policy
    if ((rc != 0)); then
        diagnostics
    fi

    if [[ $logical_created == true ]]; then
        cleanup_step "delete logical switch $logical_switch" \
            run_root 10s ovn-nbctl --timeout=5 --if-exists ls-del "$logical_switch"
    fi
    if [[ $controller_started == true ]]; then
        stop_controller=true
    elif [[ $controller_was_active == false ]] && service_active ovn-host.service; then
        stop_controller=true
    fi
    if [[ $stop_controller == true ]]; then
        cleanup_step "stop ovn-host.service" \
            run_root 20s systemctl stop ovn-host.service
    fi
    if [[ $controller_started == true ]]; then
        cleanup_step "delete chassis $chassis" \
            run_root 10s ovn-sbctl --timeout=5 --if-exists chassis-del "$chassis"
    fi
    if [[ $external_ids_set == true ]]; then
        cleanup_step "remove OVN external IDs" \
            run_root 10s ovs-vsctl --timeout=5 \
                remove Open_vSwitch . external_ids ovn-remote \
                -- remove Open_vSwitch . external_ids ovn-encap-type \
                -- remove Open_vSwitch . external_ids ovn-encap-ip
    fi
    if [[ $test_bridge_created == true ]]; then
        cleanup_step "delete bridge $test_bridge" \
            run_root 10s ovs-vsctl --timeout=5 --if-exists del-br "$test_bridge"
    fi
    if [[ $br_int_owned == true ]]; then
        cleanup_step "delete bridge br-int" \
            run_root 10s ovs-vsctl --timeout=5 --if-exists del-br br-int
    fi
    if [[ $central_started == true ]]; then
        stop_central=true
    elif [[ $central_was_active == false ]] && service_active ovn-central.service; then
        stop_central=true
    fi
    if [[ $stop_central == true ]]; then
        cleanup_step "stop ovn-central.service" \
            run_root 20s systemctl stop ovn-central.service
    fi
    if [[ $ovs_was_active == false ]]; then
        cleanup_step "stop openvswitch-switch.service" \
            run_root 20s systemctl stop openvswitch-switch.service
    fi
    cleanup_step "remove temporary directory" rm -rf -- "$tmp"
    if [[ $cleanup_failed == true && $rc == 0 ]]; then
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if service_active openvswitch-switch.service; then
    ovs_was_active=true
fi
if service_active ovn-central.service; then
    central_was_active=true
fi
if service_active ovn-host.service; then
    controller_was_active=true
fi
if [[ $ovs_was_active == true || $central_was_active == true || $controller_was_active == true ]]; then
    die "OVS, ovn-central, and ovn-host must be inactive on the dedicated exact-kernel runner"
fi

run_root 20s modprobe openvswitch
module_file=$(modinfo -F filename openvswitch)
module_vermagic=$(modinfo -F vermagic openvswitch)
printf 'openvswitch module: %s (%s)\n' "$module_file" "$module_vermagic"
[[ $module_file == "/lib/modules/$expected_uname/"* ]] || {
    die "openvswitch module is not from /lib/modules/$expected_uname: $module_file"
}
[[ ${module_vermagic%% *} == "$expected_uname" ]] || {
    die "openvswitch module vermagic does not match $expected_uname: $module_vermagic"
}
[[ -d /sys/module/openvswitch ]] || die "openvswitch module was not loaded"

if sudo -n test -L "$policy_path"; then
    die "$policy_path must not be a symlink"
fi
if sudo -n test -e "$policy_path"; then
    sudo -n test -f "$policy_path" || die "$policy_path is not a regular file"
    sudo -n cp -a -- "$policy_path" "$policy_backup"
    policy_had_file=true
fi
printf '#!/bin/sh\nexit 101\n' > "$tmp/policy-rc.d.block"
policy_installed=true
sudo -n install -o root -g root -m 0755 "$tmp/policy-rc.d.block" "$policy_path"

run_root 10m apt-get \
    -o Acquire::Retries=3 \
    -o DPkg::Lock::Timeout=120 \
    update
run_root 15m env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o DPkg::Lock::Timeout=120 \
    install -y --reinstall --no-install-recommends --allow-downgrades \
    "${ovs_packages[@]}" "${ovn_packages[@]}"
restore_policy
run_root 30s systemctl daemon-reload

for unit in openvswitch-switch.service ovsdb-server.service ovs-vswitchd.service \
    ovn-central.service ovn-host.service; do
    load_state=$(run_root 5s systemctl show --property=LoadState --value "$unit")
    [[ $load_state == loaded ]] || die "systemd unit $unit is not loaded: $load_state"
done

for deb in "${ovs_packages[@]}" "${ovn_packages[@]}"; do
    package=$(dpkg-deb -f "$deb" Package)
    expected_version=$(dpkg-deb -f "$deb" Version)
    installed_version=$(dpkg-query -W -f='${Version}' "$package")
    [[ $installed_version == "$expected_version" ]] || {
        die "$package installed as $installed_version, expected $expected_version from $deb"
    }
done

# The package post-install scripts were inhibited above. Start each layer only
# after its preconditions are in place, and keep every service operation bounded.
run_root 45s systemctl start openvswitch-switch.service
wait_for "the OVS system database" 30 \
    run_root 5s ovs-vsctl --timeout=3 show
for unit in openvswitch-switch.service ovsdb-server.service ovs-vswitchd.service; do
    service_active "$unit" || die "systemd unit $unit is not active"
done

system_id_value=$(run_root 5s ovs-vsctl --timeout=3 --if-exists get \
    Open_vSwitch . external_ids:system-id)
chassis=${system_id_value#\"}
chassis=${chassis%\"}
[[ $chassis =~ ^[A-Za-z0-9_.:-]{1,64}$ ]] || {
    die "openvswitch-switch did not create a usable system-id: $system_id_value"
}

for key in ovn-remote ovn-encap-type ovn-encap-ip; do
    value=$(run_root 5s ovs-vsctl --timeout=3 --if-exists get \
        Open_vSwitch . "external_ids:$key")
    [[ -z $value || $value == '[]' ]] || {
        die "dedicated runner already has external_ids:$key configured: $value"
    }
done
if run_root 5s ovs-vsctl --timeout=3 br-exists "$test_bridge"; then
    die "dedicated runner already has bridge $test_bridge"
fi
if run_root 5s ovs-vsctl --timeout=3 br-exists br-int; then
    die "dedicated runner already has bridge br-int"
fi
br_int_owned=true

test_bridge_created=true
run_root 10s ovs-vsctl --timeout=5 --may-exist add-br "$test_bridge"
run_root 10s ovs-vsctl --timeout=5 br-exists "$test_bridge"
run_root 10s ovs-ofctl -O OpenFlow13 show "$test_bridge" > "$tmp/test-bridge.txt"
grep -Fq "LOCAL($test_bridge)" "$tmp/test-bridge.txt" || {
    die "OVS datapath bridge $test_bridge did not expose its local port"
}

central_started=true
run_root 45s systemctl start ovn-central.service
central_ready() {
    service_active ovn-central.service &&
        run_root 5s /usr/share/ovn/scripts/ovn-ctl status_northd >/dev/null 2>&1 &&
        run_root 5s test -S /var/run/ovn/ovnnb_db.sock &&
        run_root 5s test -S /var/run/ovn/ovnsb_db.sock &&
        run_root 5s ovn-nbctl --timeout=3 show >/dev/null 2>&1 &&
        run_root 5s ovn-sbctl --timeout=3 show >/dev/null 2>&1
}
wait_for "OVN NB/SB databases and ovn-northd" 45 central_ready

logical_created=true
run_root 20s ovn-nbctl --timeout=15 --wait=sb --may-exist ls-add "$logical_switch"
run_root 20s ovn-nbctl --timeout=15 --wait=sb --may-exist \
    lsp-add "$logical_switch" "$logical_port"
run_root 20s ovn-nbctl --timeout=15 --wait=sb lsp-set-addresses \
    "$logical_port" '02:00:00:00:00:11 192.0.2.11'

external_ids_set=true
run_root 10s ovs-vsctl --timeout=5 set Open_vSwitch . \
    external_ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock \
    external_ids:ovn-encap-type=geneve \
    external_ids:ovn-encap-ip=127.0.0.1

controller_started=true
run_root 45s systemctl start ovn-host.service
controller_ready() {
    local names
    service_active ovn-host.service || return 1
    run_root 5s /usr/share/ovn/scripts/ovn-ctl status_controller >/dev/null 2>&1 || return 1
    names=$(run_root 5s ovn-sbctl --timeout=3 --bare --columns=name \
        find Chassis "name=$chassis") || return 1
    grep -Fxq "$chassis" <<< "$names"
}
wait_for "ovn-controller chassis registration" 45 controller_ready

wait_for "the controller integration bridge" 30 \
    run_root 5s ovs-vsctl --timeout=3 br-exists br-int
run_root 10s ovs-vsctl --timeout=5 --may-exist add-port br-int "$binding_iface" \
    -- set Interface "$binding_iface" type=internal \
    "external_ids:iface-id=$logical_port"
wait_for "the OVS internal binding interface" 15 \
    run_root 5s ip link set dev "$binding_iface" up

binding_ready() {
    local chassis_uuid port_chassis
    chassis_uuid=$(run_root 5s ovn-sbctl --timeout=3 --bare --columns=_uuid \
        find Chassis "name=$chassis") || return 1
    [[ $chassis_uuid =~ ^[0-9a-f-]{36}$ ]] || return 1
    port_chassis=$(run_root 5s ovn-sbctl --timeout=3 --bare --columns=chassis \
        find Port_Binding "logical_port=$logical_port") || return 1
    [[ $port_chassis == *"$chassis_uuid"* ]]
}
wait_for "logical port binding to the CI chassis" 45 binding_ready

run_root 35s ovn-nbctl --timeout=30 --wait=hv sync

port_binding=$(run_root 10s ovn-sbctl --timeout=5 --bare --columns=_uuid \
    find Port_Binding "logical_port=$logical_port")
grep -Eq '^[0-9a-f-]{36}$' <<< "$port_binding" || {
    die "northd did not create a Port_Binding for $logical_port"
}
binding_ready || die "Port_Binding for $logical_port is not bound to $chassis"
logical_flows=$(run_root 10s ovn-sbctl --timeout=5 --bare --columns=_uuid \
    find Logical_Flow)
grep -Eq '^[0-9a-f-]{36}$' <<< "$logical_flows" || {
    die "northd did not create logical flows"
}
run_root 10s ovs-ofctl -O OpenFlow13 dump-flows br-int > "$tmp/br-int.flows"
grep -Eq 'cookie=0x[0-9a-f]+' "$tmp/br-int.flows" || {
    die "ovn-controller did not install OpenFlow rules on br-int"
}

printf 'exact-kernel OVS/OVN functional smoke passed on %s\n' "$actual_uname"
