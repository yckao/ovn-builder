#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: configure-snapshot.sh SNAPSHOT_ID UBUNTU_VERSION" >&2
    exit 2
fi

snapshot=$1
ubuntu_version=$2

case "$snapshot" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) echo "invalid Ubuntu snapshot ID: $snapshot" >&2; exit 2 ;;
esac

case "$ubuntu_version" in
    22.04)
        cat > /etc/apt/sources.list <<EOF
deb https://snapshot.ubuntu.com/ubuntu/$snapshot jammy main universe restricted multiverse
deb https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-updates main universe restricted multiverse
deb https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-security main universe restricted multiverse
EOF
        ;;
    24.04)
        cat > /etc/apt/sources.list <<EOF
deb https://snapshot.ubuntu.com/ubuntu/$snapshot noble main universe restricted multiverse
deb https://snapshot.ubuntu.com/ubuntu/$snapshot noble-updates main universe restricted multiverse
deb https://snapshot.ubuntu.com/ubuntu/$snapshot noble-security main universe restricted multiverse
EOF
        ;;
    *)
        echo "unsupported Ubuntu version: $ubuntu_version" >&2
        exit 2
        ;;
esac

# A release base must not be able to reintroduce an unpinned mirror through an
# additional sources file.  The complete source set is declared above.
rm -f /etc/apt/sources.list.d/*

cat > /etc/apt/apt.conf.d/50ovn-builder-snapshot <<EOF
Acquire::Retries "3";
Acquire::Languages "none";
Acquire::Check-Valid-Until "false";
APT::Install-Recommends "false";
EOF
