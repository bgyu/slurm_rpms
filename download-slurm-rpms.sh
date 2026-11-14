#!/usr/bin/env bash

# Example usage:
#
# ./download-slurm-rpms.sh \
#  --ubi-version 10.2 \
#  --destination ~/slurm_rpms/slurm_rpms_el10_minimal

set -Eeuo pipefail

readonly PROGRAM_NAME=${0##*/}

log() {
    printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME --ubi-version VERSION --destination DIRECTORY

Download and validate a minimal Slurm RPM bundle for an x86_64 UBI image.

Required options:
  --ubi-version VERSION    UBI image tag, for example 8.7 or 10.2
  --destination DIRECTORY Publish validated RPMs into this directory

Other options:
  -h, --help               Show this help text

The host must have Podman installed and must expose a registered Red Hat
subscription to containers. Validation is performed in a separate container
with subscription secrets masked. Dependencies available from UBI or EPEL are
not included in the bundle.

UBI repositories track their major-release stream. A tag such as 8.7 selects
that base image, but currently published RPMs can have a newer EL8 minor release.
EOF
}

ubi_version=
destination=

while (($# > 0)); do
    case "$1" in
        --ubi-version)
            (($# >= 2)) || die "--ubi-version requires a value"
            [[ -z $ubi_version ]] || die "--ubi-version was specified more than once"
            ubi_version=$2
            shift 2
            ;;
        --ubi-version=*)
            [[ -z $ubi_version ]] || die "--ubi-version was specified more than once"
            ubi_version=${1#*=}
            shift
            ;;
        --destination)
            (($# >= 2)) || die "--destination requires a value"
            [[ -z $destination ]] || die "--destination was specified more than once"
            destination=$2
            shift 2
            ;;
        --destination=*)
            [[ -z $destination ]] || die "--destination was specified more than once"
            destination=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            (($# == 0)) || die "unexpected positional argument: $1"
            ;;
        -*|*)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n $ubi_version ]] || die "--ubi-version is required"
[[ -n $destination ]] || die "--destination is required"
[[ $ubi_version =~ ^[0-9]+([.][0-9]+)*$ ]] || \
    die "invalid UBI version '$ubi_version' (expected a numeric tag such as 8.7)"

command -v podman >/dev/null 2>&1 || die "podman is not installed or not in PATH"
command -v realpath >/dev/null 2>&1 || die "realpath is not installed or not in PATH"
command -v cmp >/dev/null 2>&1 || die "cmp is not installed or not in PATH"

destination=$(realpath -m -- "$destination")
[[ $destination != / ]] || die "the filesystem root cannot be used as the destination"
if [[ -e $destination && ! -d $destination ]]; then
    die "destination exists but is not a directory: $destination"
fi
destination_probe=$destination
while [[ ! -e $destination_probe ]]; do
    destination_probe=${destination_probe%/*}
    [[ -n $destination_probe ]] || destination_probe=/
done
[[ -d $destination_probe && -w $destination_probe && -x $destination_probe ]] || \
    die "destination is not writable: $destination"

readonly ubi_major=${ubi_version%%.*}
readonly image="registry.access.redhat.com/ubi${ubi_major}/ubi:${ubi_version}"

readonly -a root_packages=(
    slurm
    slurm-slurmctld
    slurm-slurmd
    slurm-slurmdbd
    slurm-slurmrestd
    munge
    mariadb
    mariadb-backup
    mariadb-common
    mariadb-connector-c
    mariadb-connector-c-config
    mariadb-errmsg
    mariadb-gssapi-server
    mariadb-server
    mariadb-server-utils
)

stage_dir=
publish_temp=
destination_created=0
publication_started=0
publication_complete=0
declare -a published_files=()

cleanup() {
    local status=$?
    trap - EXIT

    if ((publication_started && ! publication_complete)); then
        [[ -z $publish_temp ]] || rm -f -- "$publish_temp"
        if ((${#published_files[@]} > 0)); then
            rm -f -- "${published_files[@]}"
        fi
        if ((destination_created)); then
            rmdir -- "$destination" 2>/dev/null || true
        fi
    fi

    if [[ -n $stage_dir && $stage_dir == /tmp/slurm-rpms.* && -d $stage_dir ]]; then
        rm -rf -- "$stage_dir"
    fi

    exit "$status"
}
trap cleanup EXIT

stage_dir=$(mktemp -d /tmp/slurm-rpms.XXXXXX)
chmod 0700 "$stage_dir"
mkdir -p "$stage_dir/closure" "$stage_dir/bundle"

log "Using image: $image"
log "Staging downloads outside the destination until validation succeeds"

podman run --rm --interactive --pull=missing --platform linux/amd64 \
    --env EXPECTED_RHEL_MAJOR="$ubi_major" \
    --volume "$stage_dir:/work:Z" \
    "$image" \
    bash -s -- "${root_packages[@]}" <<'DOWNLOAD_CONTAINER'
set -Eeuo pipefail

container_log() {
    printf '[download container] %s\n' "$*"
}

repo_table=$(dnf -q repolist --enabled)
mapfile -t repo_ids < <(
    printf '%s\n' "$repo_table" |
        awk '$1 == "repo" && $2 == "id" { found = 1; next } found && NF { print $1 }'
)

entitled_repo_found=0
for repo_id in "${repo_ids[@]}"; do
    if [[ $repo_id == rhel-* ]]; then
        entitled_repo_found=1
        break
    fi
done
((entitled_repo_found)) || {
    printf '[download container] ERROR: no subscription-backed rhel-* repository is enabled\n' >&2
    printf '[download container] Check the host subscription and Podman secrets mount.\n' >&2
    exit 1
}

rhel_major=$(rpm -E '%{rhel}')
[[ $rhel_major =~ ^[0-9]+$ ]] || {
    printf '[download container] ERROR: could not determine the RHEL major version\n' >&2
    exit 1
}
[[ $rhel_major == "$EXPECTED_RHEL_MAJOR" ]] || {
    printf '[download container] ERROR: image reports RHEL %s, expected RHEL %s\n' \
        "$rhel_major" "$EXPECTED_RHEL_MAJOR" >&2
    exit 1
}

epel_release_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_major}.noarch.rpm"
container_log "Enabling EPEL ${rhel_major}"
dnf -y -q --setopt=install_weak_deps=False install "$epel_release_url"
dnf -q makecache --refresh

available_names=$(dnf -q repoquery --available --archlist=x86_64,noarch \
    --qf '%{name}' "$@" | sort -u)
declare -a available_packages=()
for package in "$@"; do
    if grep -Fqx -- "$package" <<<"$available_names"; then
        available_packages+=("$package")
        continue
    fi

    printf '[download container] ERROR: required root package is unavailable: %s\n' "$package" >&2
    exit 1
done

((${#available_packages[@]} > 0)) || {
    printf '[download container] ERROR: no requested packages are available\n' >&2
    exit 1
}

container_log "Downloading the root packages and temporary dependency closure"
dnf -y -q \
    --setopt=install_weak_deps=False \
    --setopt=multilib_policy=best \
    --exclude='*.i686' \
    install \
    --downloadonly \
    --downloaddir=/work/closure \
    "${available_packages[@]}"

shopt -s nullglob
rpms=(/work/closure/*.rpm)
shopt -u nullglob
((${#rpms[@]} > 0)) || {
    printf '[download container] ERROR: DNF produced no RPM files\n' >&2
    exit 1
}

downloaded_names=$(rpm --nosignature -qp --qf '%{NAME}\n' "${rpms[@]}" | sort -u)
declare -a missing_root_rpms=()
for package in "${available_packages[@]}"; do
    if ! grep -Fqx -- "$package" <<<"$downloaded_names"; then
        missing_root_rpms+=("$package")
    fi
done

if ((${#missing_root_rpms[@]} > 0)); then
    container_log "Downloading root RPMs already satisfied by the base image"
    dnf -y -q download \
        --arch=x86_64 \
        --arch=noarch \
        --destdir=/work/closure \
        "${missing_root_rpms[@]}"

    shopt -s nullglob
    rpms=(/work/closure/*.rpm)
    shopt -u nullglob
fi

downloaded_names=$(rpm --nosignature -qp --qf '%{NAME}\n' "${rpms[@]}" | sort -u)
for package in "${available_packages[@]}"; do
    grep -Fqx -- "$package" <<<"$downloaded_names" || {
        printf '[download container] ERROR: root RPM was not downloaded: %s\n' \
            "$package" >&2
        exit 1
    }
done

for rpm_path in "${rpms[@]}"; do
    rpm_arch=$(rpm --nosignature -qp --qf '%{ARCH}' "$rpm_path")
    case "$rpm_arch" in
        x86_64|noarch) ;;
        *)
            printf '[download container] ERROR: unexpected architecture %s in %s\n' \
                "$rpm_arch" "${rpm_path##*/}" >&2
            exit 1
            ;;
    esac
done

container_log "Downloaded and architecture-checked ${#rpms[@]} temporary closure RPMs"
DOWNLOAD_CONTAINER

log "Download phase completed; filtering against public UBI and EPEL repositories"

podman run --rm --interactive --pull=never --platform linux/amd64 \
    --env EXPECTED_RHEL_MAJOR="$ubi_major" \
    --tmpfs /run/secrets:rw,nosuid,nodev,noexec,notmpcopyup \
    --volume "$stage_dir:/work:Z" \
    "$image" \
    bash -s -- "${root_packages[@]}" <<'VALIDATE_CONTAINER'
set -Eeuo pipefail

container_log() {
    printf '[validation container] %s\n' "$*"
}

dnf_public=(dnf --disableplugin=subscription-manager)
rhel_major=$(rpm -E '%{rhel}')
[[ $rhel_major =~ ^[0-9]+$ ]] || {
    printf '[validation container] ERROR: could not determine the RHEL major version\n' >&2
    exit 1
}
[[ $rhel_major == "$EXPECTED_RHEL_MAJOR" ]] || {
    printf '[validation container] ERROR: image reports RHEL %s, expected RHEL %s\n' \
        "$rhel_major" "$EXPECTED_RHEL_MAJOR" >&2
    exit 1
}

epel_release_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_major}.noarch.rpm"
container_log "Enabling EPEL ${rhel_major} with subscription management disabled"
"${dnf_public[@]}" -y -q --setopt=install_weak_deps=False install "$epel_release_url"
"${dnf_public[@]}" -q makecache --refresh

repo_table=$("${dnf_public[@]}" -q repolist --enabled)
mapfile -t repo_ids < <(
    printf '%s\n' "$repo_table" |
        awk '$1 == "repo" && $2 == "id" { found = 1; next } found && NF { print $1 }'
)
((${#repo_ids[@]} > 0)) || {
    printf '[validation container] ERROR: no public repositories are enabled\n' >&2
    exit 1
}

for repo_id in "${repo_ids[@]}"; do
    case "$repo_id" in
        ubi-*|codeready-builder-for-ubi-*|epel|epel-*) ;;
        *)
            printf '[validation container] ERROR: unexpected enabled repository: %s\n' "$repo_id" >&2
            exit 1
            ;;
    esac
done

container_log "Enabled repositories are restricted to UBI and EPEL:"
printf '  %s\n' "${repo_ids[@]}"

shopt -s nullglob
closure_rpms=(/work/closure/*.rpm)
shopt -u nullglob
((${#closure_rpms[@]} > 0)) || {
    printf '[validation container] ERROR: no temporary closure RPMs were found\n' >&2
    exit 1
}

mapfile -t closure_names < <(
    rpm --nosignature -qp --qf '%{NAME}\n' "${closure_rpms[@]}" | sort -u
)
public_name_output=$(
    "${dnf_public[@]}" -q repoquery \
        --available \
        --archlist=x86_64,noarch \
        --qf '%{name}' \
        "${closure_names[@]}" |
        sort -u
)

declare -A root_name_set=()
declare -A public_name_set=()
for package in "$@"; do
    root_name_set["$package"]=1
done
while IFS= read -r package; do
    [[ -n $package ]] && public_name_set["$package"]=1
done <<<"$public_name_output"

kept_count=0
public_count=0
for rpm_path in "${closure_rpms[@]}"; do
    package=$(rpm --nosignature -qp --qf '%{NAME}' "$rpm_path")
    rpm_arch=$(rpm --nosignature -qp --qf '%{ARCH}' "$rpm_path")
    case "$rpm_arch" in
        x86_64|noarch) ;;
        *)
            printf '[validation container] ERROR: unexpected architecture %s in %s\n' \
                "$rpm_arch" "${rpm_path##*/}" >&2
            exit 1
            ;;
    esac

    if [[ -n ${root_name_set[$package]+present} || \
          -z ${public_name_set[$package]+present} ]]; then
        cp --preserve=mode,timestamps -- "$rpm_path" /work/bundle/
        ((kept_count += 1))
    else
        ((public_count += 1))
    fi
done

shopt -s nullglob
rpms=(/work/bundle/*.rpm)
shopt -u nullglob
((${#rpms[@]} > 0)) || {
    printf '[validation container] ERROR: filtering produced no bundle RPMs\n' >&2
    exit 1
}

bundle_names=$(rpm --nosignature -qp --qf '%{NAME}\n' "${rpms[@]}" | sort -u)
for package in "$@"; do
    grep -Fqx -- "$package" <<<"$bundle_names" || {
        printf '[validation container] ERROR: root RPM missing from filtered bundle: %s\n' \
            "$package" >&2
        exit 1
    }
done

container_log "Filtered ${#closure_rpms[@]} closure RPMs to ${#rpms[@]} bundle RPMs; ${public_count} dependencies remain available from UBI/EPEL"

repo_options=(--disablerepo='*')
for repo_id in "${repo_ids[@]}"; do
    repo_options+=(--enablerepo="$repo_id")
done

container_log "Installing ${#rpms[@]} local RPMs without subscription repositories"
"${dnf_public[@]}" \
    "${repo_options[@]}" \
    -y -q \
    --setopt=install_weak_deps=False \
    install "${rpms[@]}"

for package in "$@"; do
    rpm -q "$package" >/dev/null || {
        printf '[validation container] ERROR: expected package was not installed: %s\n' "$package" >&2
        exit 1
    }
done

container_log "Installation validation succeeded"
VALIDATE_CONTAINER

shopt -s nullglob
rpm_files=("$stage_dir"/bundle/*.rpm)
shopt -u nullglob
((${#rpm_files[@]} > 0)) || die "validated staging directory contains no RPMs"

shopt -s nullglob
existing_rpms=("$destination"/*.rpm)
shopt -u nullglob
for existing_path in "${existing_rpms[@]}"; do
    existing_name=${existing_path##*/}
    expected=0
    for source_path in "${rpm_files[@]}"; do
        if [[ ${source_path##*/} == "$existing_name" ]]; then
            expected=1
            break
        fi
    done
    ((expected)) || \
        die "destination contains an RPM outside the validated bundle: $existing_path"
done

for source_path in "${rpm_files[@]}"; do
    target_path="$destination/${source_path##*/}"
    if [[ -e $target_path || -L $target_path ]]; then
        [[ -f $target_path && ! -L $target_path ]] || \
            die "refusing to replace a non-regular destination entry: $target_path"
        cmp -s -- "$source_path" "$target_path" || \
            die "refusing to overwrite a different existing RPM: $target_path"
    fi
done

publication_started=1
if [[ ! -d $destination ]]; then
    mkdir -p -- "$destination"
    destination_created=1
fi

for source_path in "${rpm_files[@]}"; do
    target_path="$destination/${source_path##*/}"
    if [[ -e $target_path ]]; then
        continue
    fi

    publish_temp=$(mktemp --tmpdir="$destination" ".${source_path##*/}.tmp.XXXXXX")
    cp --preserve=mode,timestamps -- "$source_path" "$publish_temp"
    mv -- "$publish_temp" "$target_path"
    publish_temp=
    published_files+=("$target_path")
done

publication_complete=1

log "Validated RPM set is ready"
log "Image: $image"
log "Destination: $destination"
log "RPM count: ${#rpm_files[@]}"
printf '  %s\n' "${rpm_files[@]##*/}"
