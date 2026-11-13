# Minimal Slurm RPM bundle design

## Goal

Update `download-slurm-rpms.sh` so its destination contains only:

1. The explicit Slurm-cluster packages requested by the user.
2. Dependency RPMs that cannot be obtained without a Red Hat subscription from the selected UBI image's public UBI and EPEL repositories.

Dependencies available from public UBI or EPEL remain outside the bundle and are installed from those repositories later.

## Explicit packages

The script always downloads these 15 package names:

- `slurm`
- `slurm-slurmctld`
- `slurm-slurmd`
- `slurm-slurmdbd`
- `slurm-slurmrestd`
- `munge`
- `mariadb`
- `mariadb-backup`
- `mariadb-common`
- `mariadb-connector-c`
- `mariadb-connector-c-config`
- `mariadb-errmsg`
- `mariadb-gssapi-server`
- `mariadb-server`
- `mariadb-server-utils`

`slurm-libs` and `munge-libs` are dependencies rather than explicit packages. They are bundled only when public UBI/EPEL cannot supply them.

## Workflow

The host script continues to use two temporary `podman run --rm` containers.

### Entitled download container

The first container uses the host subscription secrets, enables EPEL, and runs a DNF download-only installation transaction for the 15 explicit packages. The complete transaction closure is stored in a private scratch directory. This closure is temporary and is never published directly.

### Public filtering and validation container

The second container masks `/run/secrets`, disables the subscription-manager DNF plugin, and enables only UBI and EPEL. It:

1. Reads package names from the temporary closure's RPM headers.
2. Queries public UBI/EPEL availability for those names in one batched query.
3. Copies every explicit package into a filtered bundle.
4. Copies a dependency only if its package name is unavailable from public UBI/EPEL.
5. Rejects architectures other than `x86_64` and `noarch`.
6. Performs a real installation using the filtered bundle plus UBI/EPEL.
7. Verifies the explicit cluster packages are installed.

Only the validated filtered bundle is published to the requested destination. Scratch data is removed automatically.

## Expected EL10 result

With the repositories available on 2026-11-13, UBI 10.2 produces 23 RPMs: 15 explicit packages plus eight subscription-only dependencies:

- `freeipmi`
- `librdkafka`
- `llhttp`
- `munge-libs`
- `perl-DBD-MariaDB`
- `pmix`
- `s-nail`
- `snappy`

Public dependencies such as `hdf5`, `hwloc`, `hwloc-libs`, `libjwt`, and `slurm-libs` are omitted and obtained from UBI/EPEL during installation.

The exact dependency list remains runtime-derived so the script is not tied to EL8 or EL10 package versions.

## Failure handling and verification

Missing explicit packages, unexpected repositories, architecture mismatches, dependency failures, or installation failures stop the script before publication. Existing destination collisions remain protected.

Verification covers Bash syntax, argument handling, repository isolation, output architecture, explicit-package presence, successful clean-container installation, and expected minimal output for the cached UBI 8.7 and UBI 10.2 images.
