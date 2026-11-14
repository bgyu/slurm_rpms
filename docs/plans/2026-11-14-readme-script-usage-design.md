# README script usage design

## Goal

Replace the obsolete EL8-only manual download instructions at the start of `README.md` with accurate usage documentation for `download-slurm-rpms.sh`, while retaining the existing post-installation test commands.

## Content

The updated opening documentation will include:

- Host prerequisites: Bash, Podman, network access, and a registered Red Hat subscription exposed to UBI containers.
- The script's required `--ubi-version` and `--destination` options and its `--help` option.
- A generic invocation and a concrete UBI 10.2 example.
- A short explanation of the two-container workflow and minimal-bundle filtering.
- Target installation instructions that enable public EPEL and install the bundle with subscription management disabled.
- Operational notes covering `x86_64`/`noarch`, stale destination RPM rejection, temporary closure cleanup, and rolling UBI major-release repositories.

The existing `Test after installation` section and its commands will remain unchanged.

## Verification

Verify that examples match the script's help text, Markdown fences are balanced, obsolete claims about installation without EPEL are removed, and only the intended README opening changes.
