# syntax=docker/dockerfile:1.20@sha256:26147acbda4f14c5add9946e2fd2ed543fc402884fd75146bd342a7f6271dc1d

ARG UBUNTU_BASE=ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
ARG UBUNTU_VERSION
ARG UBUNTU_CODENAME
ARG APT_SNAPSHOT
ARG CA_CERTIFICATES_URL
ARG CA_CERTIFICATES_SHA256
ARG OVS_VERSION=3.7.1
ARG OVS_COMMIT=7921d9c6924b8934ea1de9481891ac1172649280
ARG OVS_TARBALL_URL=https://www.openvswitch.org/releases/openvswitch-3.7.1.tar.gz
ARG OVS_TARBALL_SHA256=b8936c2e95a024d37123536ca843648bc2f1d2520921f991dd3d06248859b70f
ARG OVN_VERSION=26.03.2
ARG OVN_COMMIT=3facc3b5e99ba2c863ec5f47f37466397f735802
ARG OVN_UPSTREAM_OVS_GITLINK=bdb95cc1920d4ab66fe062a9470eeb33a51d33e2
ARG SOURCE_DATE_EPOCH=1781626300
ARG BUILD_JOBS=4
ARG TARGET_KERNEL
ARG KERNEL_PACKAGE_VERSION
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION

FROM scratch AS ca-certificates-package
ARG CA_CERTIFICATES_URL
ARG CA_CERTIFICATES_SHA256
ADD --checksum=sha256:${CA_CERTIFICATES_SHA256} ${CA_CERTIFICATES_URL} /ca-certificates.deb

FROM scratch AS ovs-source-archive
ARG OVS_TARBALL_URL
ARG OVS_TARBALL_SHA256
ADD --checksum=sha256:${OVS_TARBALL_SHA256} ${OVS_TARBALL_URL} /openvswitch.tar.gz

FROM scratch AS ovn-source
ARG OVN_COMMIT
ADD --keep-git-dir=true https://github.com/ovn-org/ovn.git#${OVN_COMMIT} /src/ovn/

FROM ${UBUNTU_BASE} AS snapshot-base
ARG UBUNTU_VERSION
ARG APT_SNAPSHOT
COPY --from=ca-certificates-package /ca-certificates.deb /tmp/ca-certificates.deb
COPY --chmod=0755 scripts/apt/configure-snapshot.sh /usr/local/sbin/configure-snapshot
RUN set -eux; \
    mkdir -p /tmp/ca-root /etc/ssl/certs; \
    dpkg-deb --extract /tmp/ca-certificates.deb /tmp/ca-root; \
    cat /tmp/ca-root/usr/share/ca-certificates/mozilla/*.crt > /etc/ssl/certs/ca-certificates.crt; \
    rm -rf /tmp/ca-root /tmp/ca-certificates.deb; \
    configure-snapshot "$APT_SNAPSHOT" "$UBUNTU_VERSION"

FROM snapshot-base AS builder
ARG UBUNTU_BASE
ARG UBUNTU_VERSION
ARG UBUNTU_CODENAME
ARG APT_SNAPSHOT
ARG OVS_VERSION
ARG OVS_COMMIT
ARG OVN_VERSION
ARG OVN_COMMIT
ARG OVN_UPSTREAM_OVS_GITLINK
ARG SOURCE_DATE_EPOCH
ARG TARGET_KERNEL
ARG KERNEL_PACKAGE_VERSION
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    OVS_VERSION=${OVS_VERSION} \
    OVS_COMMIT=${OVS_COMMIT} \
    OVN_VERSION=${OVN_VERSION} \
    OVN_COMMIT=${OVN_COMMIT} \
    OVN_UPSTREAM_OVS_GITLINK=${OVN_UPSTREAM_OVS_GITLINK} \
    UBUNTU_VERSION=${UBUNTU_VERSION} \
    UBUNTU_CODENAME=${UBUNTU_CODENAME} \
    APT_SNAPSHOT=${APT_SNAPSHOT} \
    BASE_IMAGE=${UBUNTU_BASE} \
    TARGET_KERNEL=${TARGET_KERNEL} \
    KERNEL_PACKAGE_VERSION=${KERNEL_PACKAGE_VERSION} \
    TARGET_ARCH=${TARGETARCH}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        devscripts \
        equivs \
        fakeroot \
        file \
        git \
        jq \
        xz-utils && \
    rm -rf /var/lib/apt/lists/*

COPY --from=ovs-source-archive /openvswitch.tar.gz /tmp/openvswitch.tar.gz
COPY --from=ovn-source /src/ovn/ /usr/src/ovn/
COPY patches/ovs/0001-reproducible-source-tar.patch /tmp/ovs-reproducible-source-tar.patch
RUN set -eux; \
    mkdir -p /usr/src/openvswitch /usr/share/ovn-builder; \
    tar --extract --gzip --file /tmp/openvswitch.tar.gz --directory /usr/src/openvswitch --strip-components=1; \
    rm /tmp/openvswitch.tar.gz; \
    test "$(git -C /usr/src/ovn rev-parse HEAD)" = "$OVN_COMMIT"; \
    test "$(git -C /usr/src/ovn ls-tree HEAD ovs | awk '{print $3}')" = "$OVN_UPSTREAM_OVS_GITLINK"; \
    patch --directory=/usr/src/openvswitch --strip=1 --input=/tmp/ovs-reproducible-source-tar.patch; \
    rm /tmp/ovs-reproducible-source-tar.patch; \
    grep -v '^# DPDK_NETDEV' /usr/src/openvswitch/debian/control.in > /usr/src/openvswitch/debian/control

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    cd /usr/src/openvswitch && \
    mk-build-deps --install --remove \
        --tool 'apt-get -y --no-install-recommends' debian/control && \
    cd /usr/src/ovn && \
    mk-build-deps --install --remove \
        --tool 'apt-get -y --no-install-recommends' debian/control && \
    rm -rf /var/lib/apt/lists/*

ARG BUILD_JOBS
ENV JOBS=${BUILD_JOBS}

COPY release-lock.json /usr/share/ovn-builder/release-lock.json
COPY --chmod=0755 scripts/build/ /usr/local/libexec/ovn-builder/
COPY --chmod=0755 scripts/bundle/create-generated.sh /usr/local/libexec/ovn-builder/create-generated-bundle

LABEL org.opencontainers.image.title="OVN and OVS reproducible build environment" \
      org.opencontainers.image.source="${REPOSITORY_SOURCE}" \
      org.opencontainers.image.version="ovn-${OVN_VERSION}_ovs-${OVS_VERSION}_ubuntu-${UBUNTU_VERSION}" \
      org.opencontainers.image.revision="${REPOSITORY_REVISION}" \
      io.ovn-builder.ovn-commit="${OVN_COMMIT}" \
      io.ovn-builder.ovs-commit="${OVS_COMMIT}" \
      io.ovn-builder.apt-snapshot="${APT_SNAPSHOT}" \
      io.ovn-builder.dpdk="false" \
      io.ovn-builder.target-kernel="${TARGET_KERNEL}"

WORKDIR /workspace
CMD ["/bin/bash"]

FROM builder AS ovs-packages
RUN --network=none \
    /usr/local/libexec/ovn-builder/build-ovs-debs.sh /usr/src/openvswitch /out

FROM builder AS ovn-packages
RUN --network=none \
    /usr/local/libexec/ovn-builder/build-ovn-debs.sh \
    /usr/src/ovn /usr/src/openvswitch /build/ovs-for-ovn /out

FROM builder AS bundle-tools
COPY --chmod=0755 scripts/bundle/verify.sh /usr/local/libexec/ovn-builder/verify-bundle

FROM bundle-tools AS ovs-bundle
COPY --from=ovs-packages /out/*.deb /bundle-input/debs/ovs/
COPY --from=ovs-packages /out/metadata/ /bundle-input/metadata/ovs/
RUN --network=none \
    PRODUCT=ovs \
    DEB_DIRS=/bundle-input/debs/ovs \
    METADATA_DIRS=/bundle-input/metadata/ovs \
    BUNDLE_DIR=/bundle/workdir \
    SOURCE_LOCK=/usr/share/ovn-builder/release-lock.json \
    /usr/local/libexec/ovn-builder/create-generated-bundle && \
    /usr/local/libexec/ovn-builder/verify-bundle /bundle/workdir

FROM bundle-tools AS ovn-bundle
COPY --from=ovs-packages /out/*.deb /bundle-input/debs/ovs/
COPY --from=ovs-packages /out/metadata/ /bundle-input/metadata/ovs/
COPY --from=ovn-packages /out/*.deb /bundle-input/debs/ovn/
COPY --from=ovn-packages /out/metadata/ /bundle-input/metadata/ovn/
RUN --network=none \
    PRODUCT=ovn \
    DEB_DIRS=/bundle-input/debs/ovs:/bundle-input/debs/ovn \
    METADATA_DIRS=/bundle-input/metadata/ovs:/bundle-input/metadata/ovn \
    BUNDLE_DIR=/bundle/workdir \
    SOURCE_LOCK=/usr/share/ovn-builder/release-lock.json \
    /usr/local/libexec/ovn-builder/create-generated-bundle && \
    /usr/local/libexec/ovn-builder/verify-bundle /bundle/workdir

FROM scratch AS ovs-export
COPY --from=ovs-bundle /bundle/workdir/ /

FROM scratch AS ovn-export
COPY --from=ovn-bundle /bundle/workdir/ /

# Raw dpkg upload-control provenance is intentionally exported separately.
# Its Build-Date is wall-clock based, so it must never enter a reproducible
# carrier or its SHA256SUMS.
FROM scratch AS ovs-provenance-export
COPY --from=ovs-packages /out/provenance/ /

FROM scratch AS ovn-provenance-export
COPY --from=ovs-packages /out/provenance/ /ovs/
COPY --from=ovn-packages /out/provenance/ /ovn/

FROM ${UBUNTU_BASE} AS ovs-deb-carrier
ARG OVS_VERSION
ARG OVS_COMMIT
ARG UBUNTU_VERSION
ARG APT_SNAPSHOT
ARG TARGET_KERNEL
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION
WORKDIR /workdir
COPY --link --chown=0:0 --from=ovs-bundle /bundle/workdir/ /workdir/
LABEL org.opencontainers.image.title="Open vSwitch DEB carrier" \
      org.opencontainers.image.source="${REPOSITORY_SOURCE}" \
      org.opencontainers.image.version="${OVS_VERSION}" \
      org.opencontainers.image.revision="${REPOSITORY_REVISION}" \
      io.ovn-builder.ovs-commit="${OVS_COMMIT}" \
      io.ovn-builder.ubuntu="${UBUNTU_VERSION}" \
      io.ovn-builder.apt-snapshot="${APT_SNAPSHOT}" \
      io.ovn-builder.target-kernel="${TARGET_KERNEL}" \
      io.ovn-builder.bundle.schema="1" \
      io.ovn-builder.bundle.profile="generated-only" \
      io.ovn-builder.payload.path="/workdir"
USER 65534:65534
CMD ["/usr/bin/sha256sum", "--check", "--strict", "SHA256SUMS"]

FROM ${UBUNTU_BASE} AS ovn-deb-carrier
ARG OVS_VERSION
ARG OVS_COMMIT
ARG OVN_VERSION
ARG OVN_COMMIT
ARG UBUNTU_VERSION
ARG APT_SNAPSHOT
ARG TARGET_KERNEL
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION
WORKDIR /workdir
COPY --link --chown=0:0 --from=ovn-bundle /bundle/workdir/ /workdir/
LABEL org.opencontainers.image.title="OVN and Open vSwitch DEB carrier" \
      org.opencontainers.image.source="${REPOSITORY_SOURCE}" \
      org.opencontainers.image.version="${OVN_VERSION}-ovs${OVS_VERSION}" \
      org.opencontainers.image.revision="${REPOSITORY_REVISION}" \
      io.ovn-builder.ovn-commit="${OVN_COMMIT}" \
      io.ovn-builder.ovs-commit="${OVS_COMMIT}" \
      io.ovn-builder.ubuntu="${UBUNTU_VERSION}" \
      io.ovn-builder.apt-snapshot="${APT_SNAPSHOT}" \
      io.ovn-builder.target-kernel="${TARGET_KERNEL}" \
      io.ovn-builder.bundle.schema="1" \
      io.ovn-builder.bundle.profile="generated-only" \
      io.ovn-builder.payload.path="/workdir"
USER 65534:65534
CMD ["/usr/bin/sha256sum", "--check", "--strict", "SHA256SUMS"]

FROM snapshot-base AS ovs-runtime
ARG OVS_VERSION
ARG OVS_COMMIT
ARG UBUNTU_VERSION
ARG APT_SNAPSHOT
ARG TARGET_KERNEL
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION
COPY --chmod=0755 scripts/runtime/policy-rc.d /usr/sbin/policy-rc.d
COPY --chmod=0755 scripts/runtime/install-debs.sh /usr/local/sbin/install-ovn-builder-debs
RUN --mount=from=ovs-bundle,source=/bundle/workdir,target=/packages,ro \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    install-ovn-builder-debs ovs /packages && \
    rm /usr/sbin/policy-rc.d /usr/local/sbin/install-ovn-builder-debs
LABEL org.opencontainers.image.title="Open vSwitch runtime" \
      org.opencontainers.image.source="${REPOSITORY_SOURCE}" \
      org.opencontainers.image.version="${OVS_VERSION}" \
      org.opencontainers.image.revision="${REPOSITORY_REVISION}" \
      io.ovn-builder.ovs-commit="${OVS_COMMIT}" \
      io.ovn-builder.ubuntu="${UBUNTU_VERSION}" \
      io.ovn-builder.apt-snapshot="${APT_SNAPSHOT}" \
      io.ovn-builder.target-kernel="${TARGET_KERNEL}"
CMD ["/usr/sbin/ovs-vswitchd", "--version"]

FROM snapshot-base AS ovn-runtime
ARG OVS_VERSION
ARG OVS_COMMIT
ARG OVN_VERSION
ARG OVN_COMMIT
ARG UBUNTU_VERSION
ARG APT_SNAPSHOT
ARG TARGET_KERNEL
ARG REPOSITORY_SOURCE
ARG REPOSITORY_REVISION
COPY --chmod=0755 scripts/runtime/policy-rc.d /usr/sbin/policy-rc.d
COPY --chmod=0755 scripts/runtime/install-debs.sh /usr/local/sbin/install-ovn-builder-debs
RUN --mount=from=ovn-bundle,source=/bundle/workdir,target=/packages,ro \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    install-ovn-builder-debs ovn /packages && \
    rm /usr/sbin/policy-rc.d /usr/local/sbin/install-ovn-builder-debs
LABEL org.opencontainers.image.title="OVN runtime with Open vSwitch" \
      org.opencontainers.image.source="${REPOSITORY_SOURCE}" \
      org.opencontainers.image.version="${OVN_VERSION}-ovs${OVS_VERSION}" \
      org.opencontainers.image.revision="${REPOSITORY_REVISION}" \
      io.ovn-builder.ovn-commit="${OVN_COMMIT}" \
      io.ovn-builder.ovs-commit="${OVS_COMMIT}" \
      io.ovn-builder.ubuntu="${UBUNTU_VERSION}" \
      io.ovn-builder.apt-snapshot="${APT_SNAPSHOT}" \
      io.ovn-builder.target-kernel="${TARGET_KERNEL}"
CMD ["/usr/bin/ovn-controller", "--version"]
