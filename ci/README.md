# CI convenience layout

The repository splits CI-related helpers into two clear subtrees:

- `ci/run/` contains the scripts the workflows actually invoke (`cmake-configure.sh`, `cmake-build.sh`, etc.). These are the orchestrators that the various `cmake-local-*` helpers and GitHub Actions call when reproducing the CI build.
- `ci/deps/` contains every dependency-related helper: the YAML-based package mappings (`ci/deps/data/deps-*.yaml`), the `packages-*.sh`/`packages-from-yaml.sh` translators, installers (`install-*-packages.sh`), and the Python `check-deps.py` validator. This keeps all packaging logic in one place.

Use `ci/run` when you want to reuse the CI configure/build/install steps, and `ci/deps` when you need dependency lists, package installers, or validation. The legacy `scripts/ci/` folder now holds only the “wrapper” entry points (e.g., `check-deps.sh`) for compatibility; the real implementations live under `ci/`.

## Ref runtime model

The reference workflows use a small runtime vocabulary:

- Generation: `linux_host`, `bsd_vm`
- Validation: `linux_container`, `bsd_vm`, `macos_host`

These names describe the execution environment, not the package manager or transport detail. In particular, `linux_container` means a Linux job running inside a container; `bsd_vm` means a BSD guest started through the VM action; and `macos_host` means a native macOS runner.

## Linting

Run local CI lint checks with:

```
bash ci/run/lint.sh
```

The script runs `actionlint` for GitHub workflows/actions and `shellcheck` for shell scripts.
Use `bash ci/run/lint.sh --changed [BASE_REF]` to lint only changed shell scripts.
Set `LINT_ACTIONLINT_WITH_SHELLCHECK=1` to also lint workflow `run:` blocks via actionlint's shellcheck integration.
By default it runs shellcheck at severity `error`; set `LINT_SHELLCHECK_SEVERITY=warning` for stricter local cleanup.

## Legacy Makefile variants

Legacy builds use three variants that map to Makefile variables as follows:

```
variant        CLIENTONLY     LOCALCLIENT
server         (unset)        (unset)
client         yes            no
localclient    yes            yes
```

Notes:
- `server` is the full server+client build (no CLIENTONLY/LOCALCLIENT set).
- `client` corresponds to `CONFTYPE=server` (client tools using server-side config).
- `localclient` corresponds to `CONFTYPE=client` (client tools using local config).
