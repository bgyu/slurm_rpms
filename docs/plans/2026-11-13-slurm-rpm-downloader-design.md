# Slurm RPM downloader design

## Goal

Create a host-side Bash script that accepts a UBI image version and destination directory, downloads a release-appropriate Slurm RPM set in an entitled UBI container, and validates that the set installs without subscription access using only local RPMs plus public UBI and EPEL repositories.

The script supports `x86_64` systems. Both `x86_64` and `noarch` RPMs are valid output.

## Interface

```bash
./download-slurm-rpms.sh \
  --ubi-version 8.7 \
  --destination /path/to/output
```

The image name is derived without a release lookup table:

```text
registry.access.redhat.com/ubi<major>/ubi:<version>
```

For example, version `8.7` selects `registry.access.redhat.com/ubi8/ubi:8.7`.

## Architecture

The host script uses two foreground, ephemeral `podman run --rm` containers. Podman Compose is unnecessary because the workflow is sequential and has no long-running service.

### Download phase

The first container retains Podman's normal host subscription-secret mount. It:

1. Verifies that at least one entitled `rhel-*` repository is enabled.
2. Installs the EPEL release package selected dynamically from the container's `%{rhel}` RPM macro.
3. Refreshes repository metadata without upgrading the base image.
4. Resolves the hardcoded seed package list for `x86_64` and `noarch`.
5. Uses a DNF download-only install transaction to capture the complete dependency closure needed by a fresh container.
6. Writes RPMs into a host staging directory mounted into the container.

The seed list mirrors `slurm_rpms_el8`. `http-parser` is retained as a preferred seed when available. On EL10 it is unavailable and current Slurm requires `llhttp`; the DNF transaction resolver selects `llhttp` through Slurm's actual shared-library requirement.

### Validation phase

The second container starts from the same UBI image but masks `/run/secrets` with an empty tmpfs and disables the subscription-manager DNF plugin. It:

1. Installs EPEL dynamically.
2. Asserts that every enabled repository is UBI, UBI CodeReady Builder, or EPEL.
3. Mounts the staged RPM directory read-only.
4. Performs a real installation of all staged RPMs.
5. Verifies that the expected Slurm packages are installed.

This proves that no subscribed RHEL repository is needed at installation time. Dependencies unavailable from public UBI/EPEL are already present in the local RPM closure.

## Publication and failure handling

Downloads remain in a private staging directory until validation succeeds. On failure, the destination is unchanged and the script removes its staging data through a trap.

Before publication, the script rejects any RPM whose architecture is not `x86_64` or `noarch`. Existing identical files may be retained, but the script refuses to overwrite a same-named RPM with different content. Successful completion prints the image used, RPM count, destination, and file list.

Invalid arguments, unavailable required seeds, missing subscription repositories, unexpected validation repositories, dependency failures, and Podman errors all produce nonzero exit status with a concise diagnostic.

## Compatibility limitation

UBI tags select a base-image version, but standard UBI repositories are rolling major-release streams. An `8.7` image can therefore resolve newer EL8-compatible packages such as `.el8_10`. The script guarantees the selected EL major family, not an exact historical minor-release repository snapshot. Exact minor pinning requires caller-provided snapshot repositories and is outside this design.

## Verification

Verification includes:

- Bash syntax and available static analysis.
- Argument and failure-path checks.
- End-to-end runs against the locally cached UBI 8.7 and UBI 10.2 images.
- Architecture inspection of every output RPM.
- Repository-isolation assertions in the validation container.
- Successful installation and Slurm package presence checks.
