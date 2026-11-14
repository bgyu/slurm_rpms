# slurm_rpms

Build and validate a minimal set of Slurm cluster RPMs for an `x86_64` UBI release. The bundle always contains the requested Slurm, Munge, and MariaDB packages, plus only those dependencies that are unavailable from public UBI and EPEL repositories.

## Prerequisites

Run the downloader from a Linux host such as Fedora under WSL with:

- Bash, Podman, and network access to Red Hat and Fedora repositories.
- A registered Red Hat subscription whose entitlement secrets are exposed to Podman containers.
- Enough temporary disk space for the complete dependency closure. Only the filtered bundle is copied to the destination.

Check the main prerequisites with:

```bash
podman --version
subscription-manager status
```

## Download a minimal bundle

The script requires a UBI image version and a destination directory:

```bash
./download-slurm-rpms.sh \
  --ubi-version VERSION \
  --destination DIRECTORY
```

For example, build a bundle using UBI 10.2:

```bash
./download-slurm-rpms.sh \
  --ubi-version 10.2 \
  --destination "$PWD/slurm_rpms_el10_minimal"
```

Show the complete command help with:

```bash
./download-slurm-rpms.sh --help
```

The script runs two temporary containers:

1. An entitled container enables EPEL and resolves the complete package transaction.
2. A clean container masks subscription secrets, removes dependencies available from public UBI/EPEL, and installs the filtered bundle to validate it.

Both containers use `--rm`, and temporary closure RPMs are deleted automatically. Only `x86_64` and `noarch` RPMs are published.

## Install the bundle

The result is a minimal bundle, not a fully offline repository. Install it in a subscription-free matching UBI environment where public UBI repositories are enabled, and enable the corresponding EPEL repository first:

```bash
bundle=/path/to/slurm_rpms_el10_minimal
rhel_major=$(rpm -E '%{rhel}')

dnf --disableplugin=subscription-manager install -y \
  "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_major}.noarch.rpm"

dnf --disableplugin=subscription-manager install -y "$bundle"/*.rpm
```

DNF obtains omitted dependencies from public UBI and EPEL repositories. The downloader already verifies this installation path in a clean container with subscription secrets masked.

## Operational notes

- Use a new or empty destination. A rerun accepts an already identical bundle, but rejects stale, additional, or conflicting RPMs rather than deleting them.
- The UBI image tag selects the base image, while standard UBI repositories track a rolling major-release stream. For example, UBI 8.7 can currently resolve newer EL8-compatible RPMs.
- The script does not require Podman Compose or manual container teardown.

## Test after installation
```bash
# Test versions
sinfo --version
squeue --version
srun --version
sbatch --version
scontrol --version

slurmctld -V
slurmd -V
slurmdbd -V
slurmrestd -V

# Verify the shared libraries
ldd "$(command -v slurmctld)"
ldd "$(command -v slurmd)"
ldd "$(command -v slurmdbd)"
ldd "$(command -v slurmrestd)"


for bin in slurmctld slurmd slurmdbd slurmrestd; do
    echo "=== $bin ==="
    ldd "$(command -v "$bin")" | grep 'not found' || echo "OK"
done

# Verify the JWT and MariaDB plugins
ldd /usr/lib64/slurm/auth_jwt.so
ldd /usr/lib64/slurm/accounting_storage_mysql.so
ldd /usr/lib64/slurm/jobcomp_mysql.so

for plugin in \
  auth_jwt \
  accounting_storage_mysql \
  jobcomp_mysql
do
    echo "=== $plugin ==="
    ldd "/usr/lib64/slurm/${plugin}.so" |
      grep 'not found' || echo "OK"
done

# Test compute-node hardware detection
slurmd -C

# More tests
echo "===== SLURM BINARIES ====="

for bin in sinfo squeue srun sbatch scontrol \
           slurmctld slurmd slurmdbd slurmrestd
do
    echo -n "$bin: "
    if command -v "$bin" >/dev/null 2>&1; then
        "$bin" -V
    else
        echo "MISSING"
    fi
done

echo
echo "===== SHARED LIBRARIES ====="

for bin in slurmctld slurmd slurmdbd slurmrestd
do
    echo -n "$bin: "
    if command -v "$bin" >/dev/null 2>&1; then
        missing=$(ldd "$(command -v "$bin")" | grep 'not found')
        if [ -z "$missing" ]; then
            echo "OK"
        else
            printf '\n%s\n' "$missing"
        fi
    else
        echo "MISSING"
    fi
done

echo
echo "===== SLURM PLUGINS ====="

for plugin in auth_jwt accounting_storage_mysql jobcomp_mysql
do
    file="/usr/lib64/slurm/${plugin}.so"
    echo -n "$plugin: "

    if [ -f "$file" ]; then
        missing=$(ldd "$file" | grep 'not found')
        if [ -z "$missing" ]; then
            echo "OK"
        else
            printf '\n%s\n' "$missing"
        fi
    else
        echo "MISSING"
    fi
done
# 

```
