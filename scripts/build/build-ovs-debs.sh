#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8 TZ=UTC
umask 022

if (($# != 2)); then
    echo "usage: build-ovs-debs.sh SOURCE_DIR NEW_OUTPUT_DIR" >&2
    exit 2
fi

source_dir=$1
output_dir=$2
jobs=${JOBS:-4}

[[ -f "$source_dir/configure" ]] || { echo "missing OVS configure script" >&2; exit 2; }
[[ ! -e "$output_dir" ]] || { echo "output already exists: $output_dir" >&2; exit 2; }
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "SOURCE_DATE_EPOCH is required" >&2; exit 2; }

install -d -m 0755 "$output_dir/metadata" "$output_dir/provenance"

pushd "$source_dir" >/dev/null
./configure --disable-afxdp
export DEB_BUILD_MAINT_OPTIONS="hardening=+all optimize=-lto"
export DEB_BUILD_OPTIONS="nodpdk nocheck noautodbgsym parallel=$jobs"
# OVS debian/rules assigns DEB_BUILD_MAINT_OPTIONS itself.  Supplying the
# value as a command-line Make variable is required to override Ubuntu's
# default LTO feature reliably.
make DEB_BUILD_MAINT_OPTIONS="$DEB_BUILD_MAINT_OPTIONS" debian-deb
popd >/dev/null

mapfile -d '' -t packages < <(
    find "$(dirname "$source_dir")" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z
)
((${#packages[@]} > 0)) || { echo "OVS build produced no DEBs" >&2; exit 1; }

for package in "${packages[@]}"; do
    install -m 0644 "$package" "$output_dir/"
done

dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
    | LC_ALL=C sort > "$output_dir/metadata/build-packages.txt"
printf '%s\n' \
    "source=openvswitch" \
    "source_version=${OVS_VERSION:?}" \
    "source_commit=${OVS_COMMIT:?}" \
    "source_date_epoch=$SOURCE_DATE_EPOCH" \
    "deb_build_maint_options=$DEB_BUILD_MAINT_OPTIONS" \
    "deb_build_options=$DEB_BUILD_OPTIONS" \
    > "$output_dir/metadata/build-environment.txt"

find "$output_dir" -depth -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +
