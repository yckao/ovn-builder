#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C TZ=UTC
umask 022

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

: "${PRODUCT:?}"
: "${DEB_DIRS:?}"
: "${METADATA_DIRS:?}"
: "${BUNDLE_DIR:?}"
: "${SOURCE_LOCK:?}"
: "${SOURCE_DATE_EPOCH:?}"
: "${JOBS:?}"
: "${UBUNTU_VERSION:?}"
: "${UBUNTU_CODENAME:?}"
: "${TARGET_ARCH:?}"
: "${APT_SNAPSHOT:?}"
: "${BASE_IMAGE:?}"
: "${OVS_VERSION:?}"
: "${OVS_COMMIT:?}"
: "${OVN_VERSION:?}"
: "${OVN_COMMIT:?}"
: "${OVN_UPSTREAM_OVS_GITLINK:?}"

case "$PRODUCT" in ovs|ovn) ;; *) die "PRODUCT must be ovs or ovn" ;; esac
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || die "invalid SOURCE_DATE_EPOCH"
[[ ! -e $BUNDLE_DIR ]] || die "bundle output already exists: $BUNDLE_DIR"
[[ -f $SOURCE_LOCK ]] || die "source lock not found: $SOURCE_LOCK"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "invalid JOBS"

jq -e \
    --arg ubuntu_version "$UBUNTU_VERSION" \
    --arg ubuntu_codename "$UBUNTU_CODENAME" \
    --arg architecture "$TARGET_ARCH" \
    --arg apt_snapshot "$APT_SNAPSHOT" \
    --arg base_image "$BASE_IMAGE" \
    --arg ovs_version "$OVS_VERSION" \
    --arg ovs_commit "$OVS_COMMIT" \
    --arg ovn_version "$OVN_VERSION" \
    --arg ovn_commit "$OVN_COMMIT" \
    --arg ovn_upstream_ovs_gitlink "$OVN_UPSTREAM_OVS_GITLINK" \
    --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
    --argjson jobs "$JOBS" '
      .schema == "io.ovn-builder.release-lock.v2" and
      .source_date_epoch == $source_date_epoch and
      .build_jobs == $jobs and
      .apt_snapshot == $apt_snapshot and
      .architecture == $architecture and
      .features.dpdk == false and
      .features.lto == false and
      .features.debug_symbols == false and
      .sources.ovs.version == $ovs_version and
      .sources.ovs.commit == $ovs_commit and
      .sources.ovn.version == $ovn_version and
      .sources.ovn.commit == $ovn_commit and
      .sources.ovn.upstream_ovs_gitlink == $ovn_upstream_ovs_gitlink and
      .sources.ovn.build_ovs_commit == $ovs_commit and
      .ubuntu[$ubuntu_version].codename == $ubuntu_codename and
      .ubuntu[$ubuntu_version].base_image == $base_image
    ' "$SOURCE_LOCK" >/dev/null || die "build inputs do not match the release lock"

install -d -m 0755 "$BUNDLE_DIR/metadata"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
: > "$tmp/packages.jsonl"

declare -A seen_files=()
declare -a deb_roots=()
IFS=: read -r -a deb_roots <<< "$DEB_DIRS"
deb_count=0
for root in "${deb_roots[@]}"; do
    [[ -d $root ]] || die "DEB directory not found: $root"
    while IFS= read -r -d '' src; do
        name=${src##*/}
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb$ ]] || die "unsafe DEB filename: $name"
        [[ -z ${seen_files[$name]+x} ]] || die "duplicate DEB filename: $name"
        seen_files[$name]=1
        dpkg-deb --info "$src" >/dev/null || die "invalid DEB: $name"
        install -m 0644 "$src" "$BUNDLE_DIR/$name"

        package=$(dpkg-deb -f "$src" Package)
        version=$(dpkg-deb -f "$src" Version)
        architecture=$(dpkg-deb -f "$src" Architecture)
        pre_depends=$(dpkg-deb -f "$src" Pre-Depends 2>/dev/null || true)
        depends=$(dpkg-deb -f "$src" Depends 2>/dev/null || true)
        recommends=$(dpkg-deb -f "$src" Recommends 2>/dev/null || true)
        sha256=$(sha256sum "$src"); sha256=${sha256%% *}
        size=$(stat -c '%s' "$src")
        component=ovs
        [[ $package == ovn-* ]] && component=ovn

        jq -cn \
            --arg file "$name" \
            --arg package "$package" \
            --arg version "$version" \
            --arg architecture "$architecture" \
            --arg component "$component" \
            --arg sha256 "$sha256" \
            --argjson size "$size" \
            --arg pre_depends "$pre_depends" \
            --arg depends "$depends" \
            --arg recommends "$recommends" \
            '{file:$file,package:$package,version:$version,architecture:$architecture,component:$component,size:$size,sha256:$sha256,pre_depends:$pre_depends,depends:$depends,recommends:$recommends,origin:"project"}' \
            >> "$tmp/packages.jsonl"
        ((deb_count += 1))
    done < <(find "$root" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
done
((deb_count > 0)) || die "no DEBs found"

declare -a metadata_roots=()
IFS=: read -r -a metadata_roots <<< "$METADATA_DIRS"
for root in "${metadata_roots[@]}"; do
    [[ -d $root ]] || continue
    component=${root%/}; component=${component##*/}
    install -d -m 0755 "$BUNDLE_DIR/metadata/$component"
    while IFS= read -r -d '' src; do
        name=${src##*/}
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9.+_~:-]*$ ]] || die "unsafe metadata filename: $name"
        case $name in
            *.buildinfo|*.changes) die "volatile dpkg provenance cannot enter a reproducible bundle: $name" ;;
        esac
        install -m 0644 "$src" "$BUNDLE_DIR/metadata/$component/$name"
    done < <(find "$root" -maxdepth 1 -type f -print0 | sort -z)
done

install -m 0644 "$SOURCE_LOCK" "$BUNDLE_DIR/metadata/source-lock.json"
release_lock_sha256=$(sha256sum "$SOURCE_LOCK"); release_lock_sha256=${release_lock_sha256%% *}

jq -S -c -s \
    --arg product "$PRODUCT" \
    --arg ubuntu_version "$UBUNTU_VERSION" \
    --arg ubuntu_codename "$UBUNTU_CODENAME" \
    --arg architecture "$TARGET_ARCH" \
    --arg apt_snapshot "$APT_SNAPSHOT" \
    --arg base_image "$BASE_IMAGE" \
    --arg ovs_version "$OVS_VERSION" \
    --arg ovs_commit "$OVS_COMMIT" \
    --arg ovn_version "$OVN_VERSION" \
    --arg ovn_commit "$OVN_COMMIT" \
    --arg ovn_upstream_ovs_gitlink "$OVN_UPSTREAM_OVS_GITLINK" \
    --arg release_lock_sha256 "$release_lock_sha256" \
    --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
    '{schema:"io.ovn-builder.deb-carrier.v2",profile:"generated-only",product:$product,payload_root:"/workdir",source:{ovs:{version:$ovs_version,commit:$ovs_commit},ovn:{version:$ovn_version,commit:$ovn_commit,upstream_ovs_gitlink:$ovn_upstream_ovs_gitlink,build_ovs_commit:$ovs_commit}},target:{ubuntu_version:$ubuntu_version,codename:$ubuntu_codename,architecture:$architecture},build:{apt_snapshot:$apt_snapshot,base_image:$base_image,source_date_epoch:$source_date_epoch,release_lock_sha256:$release_lock_sha256,dpdk:false,lto:false,debug_symbols:false,metadata_policy:"deterministic-only"},packages:sort_by(.file)}' \
    "$tmp/packages.jsonl" > "$BUNDLE_DIR/manifest.v2.json"
printf '\n' >> "$BUNDLE_DIR/manifest.v2.json"

find "$BUNDLE_DIR" -type d -exec chmod 0755 {} +
find "$BUNDLE_DIR" -type f -exec chmod 0644 {} +
find "$BUNDLE_DIR" -depth -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +

(
    cd "$BUNDLE_DIR"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
) > "$tmp/SHA256SUMS"
install -m 0644 "$tmp/SHA256SUMS" "$BUNDLE_DIR/SHA256SUMS"
# Installing SHA256SUMS changes the parent directory mtime. Normalize the full
# completed tree so the carrier layer has stable metadata as well as bytes.
find "$BUNDLE_DIR" -depth -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +
