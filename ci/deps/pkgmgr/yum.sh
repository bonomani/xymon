YUM_OPTS=()

pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

pkg_available() {
  yum -q "${YUM_OPTS[@]}" list available "$1" >/dev/null 2>&1
}

pkg_install_one() {
  ci_deps_as_root yum -y "${YUM_OPTS[@]}" install "$1"
}

pkg_pre_install() {
  echo "=== Install (Linux packages) ==="
  if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
    local needs_epel=0
    local pkg

    for pkg in "${PKGS[@]}"; do
      case "${pkg}" in
        cmake3|ninja-build)
          needs_epel=1
          break
          ;;
      esac
    done

    if [[ "${needs_epel}" == "1" ]]; then
      local basearch
      basearch="$(ci_deps_detect_rpm_basearch || true)"
      if ! ci_deps_centos7_has_epel_archive "${basearch}"; then
        echo "CentOS 7 EPEL archive is unavailable for basearch $(ci_deps_detect_rpm_basearch || echo unknown)" >&2
        return 1
      fi
      if [[ "${basearch}" == "armhfp" ]]; then
        ci_deps_install_epel7_altarch_repo
        YUM_OPTS+=(--enablerepo=ci-epel7-altarch)
      else
        ci_deps_install_epel7_archive_repo
        YUM_OPTS+=(--enablerepo=ci-epel7-archive)
      fi
    fi
    return 0
  fi

  if ci_deps_as_root yum -y "${YUM_OPTS[@]}" install epel-release; then
    if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
      YUM_OPTS+=(--enablerepo=epel)
    fi
  fi
}

if [[ "${os_name}" == "centos" && "${version}" == "7" && "${mode}" != "print" ]]; then
  ci_deps_install_centos7_vault_repo
  YUM_OPTS=(
    --disablerepo=*
    --enablerepo=centos7-vault-base
    --enablerepo=centos7-vault-updates
    --enablerepo=centos7-vault-extras
  )
fi
