# Local CMake flow

This helper set (`cmake-local-setup.sh`, `cmake-local-build.sh`, `cmake-local-install.sh`) guides you through configuring, building, and installing Xymon locally. Key points:

- **Typical interactive run**: run `cmake-local-setup.sh` without special flags, answer the prompts, and the script will configure, build, and install in order.
- **Reproducing CI**:
  1. `USE_CI_PACKAGES=1 cmake-local-setup.sh --use-ci-packages` installs packages the same way CI does.
2. Add `--use-ci-configure --preset <name> --variant server|client [--localclient ON|OFF]` to run `ci/run/cmake-configure.sh`/`ci/run/cmake-build.sh` instead of the local configure logic.
  3. Set `--no-build-install` (or `BUILD_INSTALL=0`) if you only want the configure/build without installing a prefix.
- **Defaults**: feature flags (`ENABLE_RRD/SNMP/SSL/LDAP`) default to `ON`, matching the CI builds unless you override them. Paths default to sane locations; use the `--xymon*` overrides when you need custom directories.
- **Notes**: when both `--use-ci-packages` and `--use-ci-configure` are set the helper prints an explicit note so you know the package step ran before handing control over to the CI scripts.

Refer to `cmake-local-setup.sh --help` for flag descriptions and the summary message printed during the run.
