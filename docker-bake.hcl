variable "IMAGE_PREFIX" {
  default = "local/ovn-builder"
}

variable "PLATFORM" {
  default = "linux/amd64"
}

variable "RELEASE_REVISION" {
  default = "r1"
}

variable "SOURCE_DATE_EPOCH" {
  default = "1781626300"
}

variable "BUILD_JOBS" {
  default = "4"
}

variable "REPOSITORY_SOURCE" {
  default = ""
}

variable "REPOSITORY_REVISION" {
  default = ""
}

variable "OVS_VERSION" {
  default = "3.7.1"
}

variable "OVS_COMMIT" {
  default = "7921d9c6924b8934ea1de9481891ac1172649280"
}

variable "OVN_VERSION" {
  default = "26.03.2"
}

variable "OVN_COMMIT" {
  default = "3facc3b5e99ba2c863ec5f47f37466397f735802"
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = [PLATFORM]
  args = {
    OVS_VERSION              = OVS_VERSION
    OVS_COMMIT               = OVS_COMMIT
    OVS_TARBALL_URL          = "https://www.openvswitch.org/releases/openvswitch-3.7.1.tar.gz"
    OVS_TARBALL_SHA256       = "b8936c2e95a024d37123536ca843648bc2f1d2520921f991dd3d06248859b70f"
    OVN_VERSION              = OVN_VERSION
    OVN_COMMIT               = OVN_COMMIT
    OVN_UPSTREAM_OVS_GITLINK = "bdb95cc1920d4ab66fe062a9470eeb33a51d33e2"
    SOURCE_DATE_EPOCH        = SOURCE_DATE_EPOCH
    BUILD_JOBS               = BUILD_JOBS
    REPOSITORY_SOURCE        = REPOSITORY_SOURCE
    REPOSITORY_REVISION      = REPOSITORY_REVISION
  }
}

target "_u2204" {
  args = {
    UBUNTU_BASE              = "ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc"
    UBUNTU_VERSION           = "22.04"
    UBUNTU_CODENAME          = "jammy"
    APT_SNAPSHOT             = "20260820T000000Z"
    CA_CERTIFICATES_URL      = "https://snapshot.ubuntu.com/ubuntu/20260820T000000Z/pool/main/c/ca-certificates/ca-certificates_20260601~22.04.1_all.deb"
    CA_CERTIFICATES_SHA256   = "6e8cdcc8c86103acd4fc14649eac62ff2037108389074a7b167567af33c32245"
    TARGET_KERNEL            = "6.8.0-52-generic"
    KERNEL_PACKAGE_VERSION   = "6.8.0-52.53~22.04.1"
  }
}

target "_u2404" {
  args = {
    UBUNTU_BASE              = "ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517"
    UBUNTU_VERSION           = "24.04"
    UBUNTU_CODENAME          = "noble"
    APT_SNAPSHOT             = "20260820T000000Z"
    CA_CERTIFICATES_URL      = "https://snapshot.ubuntu.com/ubuntu/20260820T000000Z/pool/main/c/ca-certificates/ca-certificates_20260601~24.04.1_all.deb"
    CA_CERTIFICATES_SHA256   = "6bac2a01979e210d9eac1d4d56747ec709ea60654744d66705dc3c36e7629e50"
    TARGET_KERNEL            = "6.8.0-138-generic"
    KERNEL_PACKAGE_VERSION   = "6.8.0-138.138"
  }
}

target "builder-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "builder"
  tags     = ["${IMAGE_PREFIX}/builder:ovn${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu22.04-amd64"]
}

target "builder-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "builder"
  tags     = ["${IMAGE_PREFIX}/builder:ovn${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu24.04-amd64"]
}

target "debs-ovs-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovs-export"
  output   = ["type=local,dest=./dist/ovs/u2204"]
}

target "debs-ovs-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovs-export"
  output   = ["type=local,dest=./dist/ovs/u2404"]
}

target "debs-ovn-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovn-export"
  output   = ["type=local,dest=./dist/ovn/u2204"]
}

target "debs-ovn-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovn-export"
  output   = ["type=local,dest=./dist/ovn/u2404"]
}

target "provenance-ovs-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovs-provenance-export"
  output   = ["type=local,dest=./dist/provenance/ovs/u2204"]
}

target "provenance-ovs-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovs-provenance-export"
  output   = ["type=local,dest=./dist/provenance/ovs/u2404"]
}

target "provenance-ovn-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovn-provenance-export"
  output   = ["type=local,dest=./dist/provenance/ovn/u2204"]
}

target "provenance-ovn-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovn-provenance-export"
  output   = ["type=local,dest=./dist/provenance/ovn/u2404"]
}

target "carrier-ovs-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovs-deb-carrier"
  tags     = ["${IMAGE_PREFIX}/ovs-debs:${OVS_VERSION}-${RELEASE_REVISION}-ubuntu22.04-amd64"]
}

target "carrier-ovs-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovs-deb-carrier"
  tags     = ["${IMAGE_PREFIX}/ovs-debs:${OVS_VERSION}-${RELEASE_REVISION}-ubuntu24.04-amd64"]
}

target "carrier-ovn-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovn-deb-carrier"
  tags     = ["${IMAGE_PREFIX}/ovn-debs:${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu22.04-amd64"]
}

target "carrier-ovn-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovn-deb-carrier"
  tags     = ["${IMAGE_PREFIX}/ovn-debs:${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu24.04-amd64"]
}

target "runtime-ovs-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovs-runtime"
  tags     = ["${IMAGE_PREFIX}/ovs:${OVS_VERSION}-${RELEASE_REVISION}-ubuntu22.04-amd64"]
}

target "runtime-ovs-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovs-runtime"
  tags     = ["${IMAGE_PREFIX}/ovs:${OVS_VERSION}-${RELEASE_REVISION}-ubuntu24.04-amd64"]
}

target "runtime-ovn-u2204" {
  inherits = ["_common", "_u2204"]
  target   = "ovn-runtime"
  tags     = ["${IMAGE_PREFIX}/ovn:${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu22.04-amd64"]
}

target "runtime-ovn-u2404" {
  inherits = ["_common", "_u2404"]
  target   = "ovn-runtime"
  tags     = ["${IMAGE_PREFIX}/ovn:${OVN_VERSION}-ovs${OVS_VERSION}-${RELEASE_REVISION}-ubuntu24.04-amd64"]
}

group "images-ovs-u2204" {
  targets = ["carrier-ovs-u2204", "runtime-ovs-u2204"]
}

group "images-ovs-u2404" {
  targets = ["carrier-ovs-u2404", "runtime-ovs-u2404"]
}

group "images-ovn-u2204" {
  targets = ["carrier-ovn-u2204", "runtime-ovn-u2204"]
}

group "images-ovn-u2404" {
  targets = ["carrier-ovn-u2404", "runtime-ovn-u2404"]
}

group "all-images" {
  targets = [
    "images-ovs-u2204",
    "images-ovs-u2404",
    "images-ovn-u2204",
    "images-ovn-u2404",
    "builder-u2204",
    "builder-u2404"
  ]
}

group "default" {
  targets = [
    "debs-ovs-u2204",
    "debs-ovs-u2404",
    "debs-ovn-u2204",
    "debs-ovn-u2404"
  ]
}
