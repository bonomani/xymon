# CI convenience layout

The repository splits CI-related helpers into two clear subtrees:

- `ci/run/` contains the scripts the workflows actually invoke (`cmake-configure.sh`, `cmake-build.sh`, etc.). These are the orchestrators that the various `cmake-local-*` helpers and GitHub Actions call when reproducing the CI build.
- `ci/deps/` contains every dependency-related helper: the YAML-based package mappings (`ci/deps/data/deps-*.yaml`), the `packages-*.sh`/`packages-from-yaml.sh` translators, installers (`install-*-packages.sh`), and the Python `check-deps.py` validator. This keeps all packaging logic in one place.

Use `ci/run` when you want to reuse the CI configure/build/install steps, and `ci/deps` when you need dependency lists, package installers, or validation. The legacy `scripts/ci/` folder now holds only the “wrapper” entry points (e.g., `check-deps.sh`) for compatibility; the real implementations live under `ci/`.
