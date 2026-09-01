#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8 TZ=UTC
umask 022

if (($# != 4)); then
    echo "usage: build-ovn-debs.sh OVN_SOURCE OVS_SOURCE NEW_OVS_BUILD NEW_OUTPUT_DIR" >&2
    exit 2
fi

ovn_source=$1
ovs_source=$2
ovs_build=$3
output_dir=$4
jobs=${JOBS:-4}

[[ -f "$ovn_source/debian/control" ]] || { echo "missing OVN Debian packaging" >&2; exit 2; }
[[ -f "$ovs_source/configure" ]] || { echo "missing OVS configure script" >&2; exit 2; }
[[ ! -e "$ovs_build" ]] || { echo "OVS build directory already exists" >&2; exit 2; }
[[ ! -e "$output_dir" ]] || { echo "output already exists: $output_dir" >&2; exit 2; }
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "SOURCE_DATE_EPOCH is required" >&2; exit 2; }

install -d -m 0755 "$ovs_build" "$output_dir/metadata" "$output_dir/provenance"

pushd "$ovs_build" >/dev/null
export DEB_BUILD_MAINT_OPTIONS="hardening=+all optimize=-lto"
CFLAGS="$(dpkg-buildflags --get CFLAGS)" \
CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS)" \
LDFLAGS="$(dpkg-buildflags --get LDFLAGS)" \
"$ovs_source/configure" \
    --prefix=/usr \
    --localstatedir=/var \
    --sysconfdir=/etc \
    --enable-ssl \
    --with-pic \
    --disable-afxdp
make -j"$jobs"
popd >/dev/null

pushd "$ovn_source" >/dev/null
export OVSDIR=$ovs_source
export EXTRA_CONFIGURE_OPTS="--with-ovs-build=$ovs_build"
export DEB_BUILD_OPTIONS="nocheck noautodbgsym parallel=$jobs"
dpkg-buildpackage -b -us -uc
popd >/dev/null

parent=$(dirname "$ovn_source")
mapfile -d '' -t packages < <(
    find "$parent" -maxdepth 1 -type f -name 'ovn*.deb' -print0 | sort -z
)
((${#packages[@]} > 0)) || { echo "OVN build produced no DEBs" >&2; exit 1; }

for package in "${packages[@]}"; do
    install -m 0644 "$package" "$output_dir/"
done

# dpkg-buildpackage emits .buildinfo with a wall-clock Build-Date, and the
# matching .changes file hashes it. Preserve those bytes as separate per-run
# provenance, outside the reproducible carrier payload.
for pattern in 'ovn_*.buildinfo' 'ovn_*.changes'; do
    for provenance in "$parent"/$pattern; do
        [[ -e $provenance ]] || continue
        install -m 0644 "$provenance" "$output_dir/provenance/"
    done
done

dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
    | LC_ALL=C sort > "$output_dir/metadata/build-packages.txt"
printf '%s\n' \
    "source=ovn" \
    "source_version=${OVN_VERSION:?}" \
    "source_commit=${OVN_COMMIT:?}" \
    "build_ovs_version=${OVS_VERSION:?}" \
    "build_ovs_commit=${OVS_COMMIT:?}" \
    "source_date_epoch=$SOURCE_DATE_EPOCH" \
    "deb_build_maint_options=$DEB_BUILD_MAINT_OPTIONS" \
    "deb_build_options=$DEB_BUILD_OPTIONS" \
    "dpkg_run_provenance=excluded-from-reproducible-bundle" \
    > "$output_dir/metadata/build-environment.txt"

find "$output_dir" -depth -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +
