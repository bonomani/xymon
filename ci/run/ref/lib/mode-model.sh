#!/usr/bin/env bash

# Shared mode-model helpers for ref lane orchestration.
# Functions return non-zero on invalid input and print a reason to stderr.

normalize_allow_failure_mode() {
  local raw="${1:-}"
  case "${raw}" in
    false|0|no)
      printf 'off\n'
      ;;
    true|1|yes)
      printf 'allow\n'
      ;;
    *)
      printf '%s\n' "${raw}"
      ;;
  esac
}

validate_goal_ref_publish() {
  local goal="${1:-}"
  local ref_mode="${2:-}"
  local publish="${3:-}"

  case "${goal}" in
    verify|ref)
      ;;
    *)
      echo "Unsupported goal: ${goal}" >&2
      return 2
      ;;
  esac

  case "${ref_mode}" in
    generate|compare)
      ;;
    *)
      echo "Unsupported ref_mode: ${ref_mode}" >&2
      return 2
      ;;
  esac

  case "${publish}" in
    none|artifact)
      ;;
    *)
      echo "Unsupported publish: ${publish}" >&2
      return 2
      ;;
  esac

  if [[ "${goal}" != "ref" && "${ref_mode}" == "compare" ]]; then
    echo "ref_mode=compare is only valid when goal=ref" >&2
    return 2
  fi
  if [[ "${goal}" == "verify" && "${ref_mode}" != "generate" ]]; then
    echo "goal=verify requires ref_mode=generate" >&2
    return 2
  fi
  if [[ "${goal}" == "verify" && "${publish}" != "none" ]]; then
    echo "goal=verify requires publish=none" >&2
    return 2
  fi

  return 0
}

validate_allow_failure_mode() {
  local mode="${1:-}"
  case "${mode}" in
    off|allow|expect_fail)
      return 0
      ;;
    *)
      echo "Unsupported allow_failure_mode: ${mode}" >&2
      return 2
      ;;
  esac
}

validate_requested_build_tool() {
  local build_tool="${1:-}"
  case "${build_tool}" in
    auto|make|cmake)
      return 0
      ;;
    *)
      echo "Unsupported requested_build_tool: ${build_tool}" >&2
      return 2
      ;;
  esac
}

validate_lane_build_tool() {
  local build_tool="${1:-}"
  case "${build_tool}" in
    make|cmake)
      return 0
      ;;
    *)
      echo "Unsupported lane build_tool: ${build_tool}" >&2
      return 2
      ;;
  esac
}

resolve_build_tool() {
  local requested_build_tool="${1:-}"
  local goal="${2:-}"
  local ref_mode="${3:-}"

  if [[ "${requested_build_tool}" == "auto" ]]; then
    if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
      printf 'cmake\n'
    else
      printf 'make\n'
    fi
    return 0
  fi

  printf '%s\n' "${requested_build_tool}"
}

derive_dep_mode() {
  local goal="${1:-}"
  local ref_mode="${2:-}"

  if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
    printf 'compare\n'
  else
    printf 'generate\n'
  fi
}

derive_purpose() {
  local goal="${1:-}"
  local ref_mode="${2:-}"

  if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
    printf 'validation\n'
  else
    printf 'generation\n'
  fi
}
