# CI convenience layout

The repository splits CI-related helpers into two clear subtrees:

- `ci/run/` contains the scripts the workflows actually invoke (`cmake-configure.sh`, `cmake-build.sh`, etc.). These are the orchestrators that the various `cmake-local-*` helpers and GitHub Actions call when reproducing the CI build.
- `ci/deps/` contains every dependency-related helper: the YAML-based package mappings (`ci/deps/data/deps-*.yaml`), the `packages-*.sh`/`packages-from-yaml.sh` translators (the shell script still looks up the top-level selector keys with its AWK/grep loop so it can run without Python, and we keep that parser by default while optionally wiring a `PYTHONPATH`/`--python` mode to invoke `check-deps.py`’s loader for richer validation when Python is available), the centralized `install-packages.sh --pkgmgr NAME` installer (plus BSD-specific helpers), and the Python `check-deps.py` validator. This keeps all packaging logic in one place.

Use `ci/run` when you want to reuse the CI configure/build/install steps, and `ci/deps` when you need dependency lists, package installers, or validation. The legacy `scripts/ci/` folder now holds only the “wrapper” entry points (e.g., `check-deps.sh`) for compatibility; the real implementations live under `ci/`.

## Ref runtime model

The reference workflows use one shared runtime vocabulary:

- `linux_host`
- `linux_container`
- `bsd_vm`
- `macos_host`

These names describe the execution environment, not the package manager or transport detail. In particular, `linux_container` means a Linux job running inside a container; `bsd_vm` means a BSD guest started through the VM action; and `macos_host` means a native macOS runner.

Generation and validation both route lanes through those runtime buckets. A
given manifest can still use only the subset it actually needs today.

## Ref family catalog

Reference generation and reference validation now share one family catalog:
`ci/run/ref/ref-families.yml`.

Each family can expose a `generation` section, a `validation` section, or
both. The selectors stay separate, but they derive their family lists from the
same manifest and only see the purpose-specific entries.

Lane objects keep two OS concepts separate:

- `ref_os`: the logical OS namespace used by the legacy bootstrap and ref paths
- `platform_os`: the concrete platform family the lane actually runs on

For example, Linux container lanes may run on `platform_os=alpine` or
`platform_os=oraclelinux` while still generating or validating the shared
`ref_os=linux` reference set.

## Oracle Linux validation family

Reference validation keeps Oracle Linux as its own Linux-container family even
though it remains part of the RPM packaging world.

- Recommended matrix: `oraclelinux:10`, `oraclelinux:9`, `oraclelinux:8`
- Optional matrix lanes: `oraclelinux:10` on arm64, `oraclelinux:10-slim`
- Oracle Linux is RPM-based and uses `dnf` on OL8/9/10
- Package payloads remain `.rpm`, and package presence checks use `rpm -q`

The requested `oraclelinux:10-fips` lane is intentionally not wired because
that tag is not currently published in the upstream container image set.

## Linting

Run local CI lint checks with:

```
bash ci/run/lint.sh
```

The script runs `actionlint` for GitHub workflows/actions and `shellcheck` for shell scripts.
Use `bash ci/run/lint.sh --changed [BASE_REF]` to lint only changed shell scripts.
Set `LINT_ACTIONLINT_WITH_SHELLCHECK=1` to also lint workflow `run:` blocks via actionlint's shellcheck integration.
By default it runs shellcheck at severity `error`; set `LINT_SHELLCHECK_SEVERITY=warning` for stricter local cleanup.

For targeted script regression checks, run:

```
bash ci/run/tests/test-cmake-bsdlocal.sh
```

This covers the local-only `bsdlocal` preset and the fallback path used when
the host CMake version is older than 3.23.

If you need to override the BSD local roots through the local wrappers, export
`XYMON_BSD_LOCALBASE` and `XYMON_BSD_LOCALSTATEDIR` before running the CMake
configure helpers.

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

The legacy helpers under `ci/run/` still call the autotools flow directly (`legacy-configure.sh` runs `./configure --${VARIANT}` with the same feature flags, and `legacy-build.sh` runs `make -j1`). They remain unchanged so the old workflow continues to behave exactly as it did before the CMake transition.
