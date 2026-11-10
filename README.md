# slurm_rpms
slurm packages for rhel 8.7

## Install epel repo
dnf install -y \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm

This extra repo is used to download slurm-* and hdf5 packages.

Download packages for later installation:
```bash
# Other packages in this repo can be downloaded in the same way
dnf download --downloaddir=/var/packages hdf5-1.10.5-4.el8.x86_64
```

Install on other RHEL 8.7 machine (without epel)

```bash
dnf install -y *.rpm
```

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
