#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 3)) || die "usage: smoke-builder.sh BUILDER_TAR BUILDER_IMAGE EXPECTED_UBUNTU"

builder_tar=$1
builder_image=$2
expected_ubuntu=$3

[[ -f $builder_tar && ! -L $builder_tar ]] || die "builder archive is missing or unsafe: $builder_tar"
[[ $expected_ubuntu == 22.04 || $expected_ubuntu == 24.04 ]] \
    || die "unsupported Ubuntu version: $expected_ubuntu"

docker load --input "$builder_tar" >/dev/null

[[ $(docker image inspect -f '{{.Config.WorkingDir}}' "$builder_image") == /workspace ]] \
    || die "builder WorkingDir is not /workspace"
if [[ -n ${REPOSITORY_SOURCE:-} ]]; then
    [[ $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$builder_image") == "$REPOSITORY_SOURCE" ]] \
        || die "builder source label is wrong"
fi
if [[ -n ${REPOSITORY_REVISION:-} ]]; then
    [[ $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$builder_image") == "$REPOSITORY_REVISION" ]] \
        || die "builder repository revision label is wrong"
fi
[[ $(docker image inspect -f '{{index .Config.Labels "io.ovn-builder.ubuntu"}}' "$builder_image") == "$expected_ubuntu" ]] \
    || die "builder Ubuntu label is wrong"

docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --env "EXPECTED_UBUNTU=$expected_ubuntu" \
    --entrypoint /bin/bash \
    "$builder_image" -ceu '
        test "$UBUNTU_VERSION" = "$EXPECTED_UBUNTU"
        test -n "$OVS_VERSION"
        test -n "$OVN_VERSION"
        test -f /usr/share/ovn-builder/release-lock.json
        test -f /usr/src/openvswitch/configure
        test -d /usr/src/ovn/.git
        test "$(git -C /usr/src/ovn rev-parse HEAD)" = "$OVN_COMMIT"
        test "$(git -C /usr/src/ovn ls-tree HEAD ovs | awk "{print \$3}")" = "$OVN_UPSTREAM_OVS_GITLINK"
        test "$(jq -r .sources.ovs.commit /usr/share/ovn-builder/release-lock.json)" = "$OVS_COMMIT"
        test "$(jq -r .sources.ovn.commit /usr/share/ovn-builder/release-lock.json)" = "$OVN_COMMIT"
        for tool in \
            autoconf automake dpkg-buildpackage dpkg-checkbuilddeps gcc git jq \
            libtoolize make mk-build-deps; do
            command -v "$tool" >/dev/null
        done
        dpkg-checkbuilddeps /usr/src/openvswitch/debian/control
        dpkg-checkbuilddeps /usr/src/ovn/debian/control
        test -x /usr/local/libexec/ovn-builder/build-ovs-debs.sh
        test -x /usr/local/libexec/ovn-builder/build-ovn-debs.sh
    '

echo "builder image smoke test passed for Ubuntu $expected_ubuntu"
