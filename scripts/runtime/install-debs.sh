#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 TZ=UTC

if (($# != 2)); then
    echo "usage: install-debs.sh PRODUCT BUNDLE_DIR" >&2
    exit 2
fi

product=$1
bundle_dir=$2
[[ -d "$bundle_dir" ]] || { echo "missing bundle directory: $bundle_dir" >&2; exit 2; }

declare -a package_names=(openvswitch-common openvswitch-switch python3-openvswitch)
case "$product" in
    ovs) ;;
    ovn) package_names+=(ovn-common ovn-host ovn-central) ;;
    *) echo "unsupported runtime product: $product" >&2; exit 2 ;;
esac

declare -a package_paths=()
for package_name in "${package_names[@]}"; do
    mapfile -d '' -t matches < <(
        find "$bundle_dir" -maxdepth 1 -type f -name "${package_name}_*.deb" -print0 | sort -z
    )
    ((${#matches[@]} == 1)) || {
        echo "expected one $package_name package, found ${#matches[@]}" >&2
        exit 1
    }
    package_paths+=("${matches[0]}")
done

apt-get update
apt-get install -y --no-install-recommends ca-certificates "${package_paths[@]}"
rm -rf /var/lib/apt/lists/*
