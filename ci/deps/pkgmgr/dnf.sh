DNF_REPO_ARGS=()

configure_rocky_fallback_repos() {
  [[ "${os_name}" == "rockylinux" ]] || return 0
  ci_deps_configure_rocky_fallback_repos "${os_name}" "${version}" || return 1

  DNF_REPO_ARGS=(
    --disablerepo=baseos
    --disablerepo=appstream
    --disablerepo=extras
    --enablerepo=ci-rocky-baseos
    --enablerepo=ci-rocky-appstream
    --enablerepo=ci-rocky-extras
  )
}

configure_enterprise_builder_repos() {
  if [[ "${os_name}" == "rockylinux" || "${os_name}" == "almalinux" ]]; then
    if [[ "${version}" == "8" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled powertools || true
    elif [[ "${version}" == "9" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled crb || true
    fi
    return 0
  fi

  if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
    ci_deps_as_root dnf config-manager --set-enabled "ol${version}_codeready_builder" || true
  fi
}

install_optional_epel_release() {
  local epel_package="epel-release"

  if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
    epel_package="oracle-epel-release-el${version}"
  fi

  dnf_run -y install "${epel_package}" || true
}

dnf_run() {
  if ((${#DNF_REPO_ARGS[@]})); then
    ci_deps_as_root dnf "${DNF_REPO_ARGS[@]}" "$@"
  else
    ci_deps_as_root dnf "$@"
  fi
}

pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

pkg_available() {
  if ((${#DNF_REPO_ARGS[@]})); then
    dnf -q "${DNF_REPO_ARGS[@]}" list --available "$1" >/dev/null 2>&1
  else
    dnf -q list --available "$1" >/dev/null 2>&1
  fi
}

pkg_install_one() {
  dnf_run -y install "$1"
}

pkg_pre_install() {
  # Configure repos, then refresh metadata (dnf_run -y makecache below).
  configure_rocky_fallback_repos
  dnf_run -y install dnf-plugins-core
  configure_enterprise_builder_repos
  install_optional_epel_release
  dnf_run clean all
  dnf_run -y makecache
}
