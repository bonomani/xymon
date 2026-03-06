"""Shell lint checks used by ci/deps/check-deps.py."""

from __future__ import annotations

import subprocess


def check_shell_scripts(root) -> bool:
    scripts = [
        root / "cmake-local-setup.sh",
        root / "cmake-local-build.sh",
        root / "cmake-local-install.sh",
        root / "ci" / "deps" / "install-default-packages.sh",
        root / "ci" / "deps" / "install-checkout-tools.sh",
        root / "ci" / "deps" / "install-apt-packages.sh",
        root / "ci" / "deps" / "install-apk-packages.sh",
        root / "ci" / "deps" / "install-bsd-packages.sh",
        root / "ci" / "deps" / "install-brew-packages.sh",
        root / "ci" / "deps" / "install-pkg-packages.sh",
        root / "ci" / "deps" / "install-pkg-add-packages.sh",
        root / "ci" / "deps" / "install-pkgin-packages.sh",
        root / "ci" / "deps" / "install-dnf-packages.sh",
        root / "ci" / "deps" / "install-pacman-packages.sh",
        root / "ci" / "deps" / "install-yum-packages.sh",
        root / "ci" / "deps" / "install-zypper-packages.sh",
        root / "ci" / "deps" / "lib" / "install-common.sh",
        root / "ci" / "deps" / "lib" / "install-bsd-common.sh",
        root / "ci" / "run" / "ref" / "resolve-execution-model.sh",
    ]
    existing = [str(path) for path in scripts if path.exists()]
    if not existing:
        print("   NOTE: no shell scripts found for linting")
        return True

    try:
        subprocess.run(
            ["shellcheck", "--version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print("   NOTE: shellcheck not installed; skipping shell lint")
        return True

    cmd = [
        "shellcheck",
        "--external-sources",
        "--shell",
        "bash",
        "--severity",
        "warning",
    ] + existing
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("   ERROR: shellcheck reported issues")
        return False
    return True
