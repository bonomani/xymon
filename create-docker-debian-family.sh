#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
BASE_DIR="${ROOT_DIR}/docker"
MATRIX_FILE="${ROOT_DIR}/ci/deps/docker-matrix.yaml"
PLATFORM_CATALOG_FILE="${ROOT_DIR}/ci/deps/platform-catalog.yaml"

if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "Missing matrix definition: $MATRIX_FILE" >&2
  exit 1
fi

if [[ ! -f "$PLATFORM_CATALOG_FILE" ]]; then
  echo "Missing platform catalog: $PLATFORM_CATALOG_FILE" >&2
  exit 1
fi

trim() {
  local val="$1"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

unquote() {
  local val="$1"
  if [[ "${val}" =~ ^\".*\"$ || "${val}" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

parse_platform_catalog() {
  local section=""
  local current_platform=""
  local current_profile=""
  local in_deps=0
  local line=""
  local trimmed=""
  local key=""
  local value=""
  local profile=""
  local field=""
  local platform_id=""
  local leading=""
  local indent=0
  declare -A seen_platforms=()

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%$'\r'}"
    leading="${line%%[^ ]*}"
    indent="${#leading}"
    trimmed="$(trim "$line")"
    [[ -z "$trimmed" || ${trimmed:0:1} == "#" ]] && continue

    if [[ "$indent" -eq 0 && "$trimmed" == "binding_profiles:" ]]; then
      section="binding_profiles"
      current_profile=""
      current_platform=""
      in_deps=0
      continue
    fi

    if [[ "$indent" -eq 0 && "$trimmed" == "platforms:" ]]; then
      section="platforms"
      current_platform=""
      current_profile=""
      in_deps=0
      continue
    fi

    if [[ "${section}" == "binding_profiles" ]]; then
      if [[ "$indent" -eq 2 && "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
        current_profile="${BASH_REMATCH[1]}"
        continue
      fi

      if [[ -n "$current_profile" && "$indent" -ge 4 && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="$(trim "${BASH_REMATCH[2]}")"
        value="$(unquote "${value}")"
        binding_profiles["${current_profile}:${key}"]="${value}"
      fi
      continue
    fi

    if [[ "${section}" != "platforms" ]]; then
      continue
    fi

    if [[ "$indent" -eq 2 && "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
      current_platform="${BASH_REMATCH[1]}"
      seen_platforms["${current_platform}"]=1
      in_deps=0
      continue
    fi

    if [[ -z "$current_platform" ]]; then
      continue
    fi

    if [[ "$indent" -eq 4 && "$trimmed" == "deps:" ]]; then
      in_deps=1
      continue
    fi

    if [[ "$indent" -eq 4 && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(trim "${BASH_REMATCH[2]}")"
      value="$(unquote "${value}")"
      platform_catalog["${current_platform}:${key}"]="${value}"
      in_deps=0
      continue
    fi

    if [[ "$in_deps" -eq 1 && "$indent" -ge 6 && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(trim "${BASH_REMATCH[2]}")"
      value="$(unquote "${value}")"
      platform_deps["${current_platform}:${key}"]="${value}"
    fi
  done < "$PLATFORM_CATALOG_FILE"

  for platform_id in "${!seen_platforms[@]}"; do
    profile="${platform_deps["${platform_id}:profile"]:-}"
    [[ -n "${profile}" ]] || continue

    if [[ -z "${binding_profiles["${profile}:family"]:-}" || -z "${binding_profiles["${profile}:os"]:-}" ]]; then
      echo "Binding profile '${profile}' not found or incomplete for platform '${platform_id}'" >&2
      exit 1
    fi

    for field in family os version; do
      if [[ -z "${platform_deps["${platform_id}:${field}"]:-}" && -n "${binding_profiles["${profile}:${field}"]:-}" ]]; then
        platform_deps["${platform_id}:${field}"]="${binding_profiles["${profile}:${field}"]}"
      fi
    done
  done
}

parse_matrix() {
  local current=""
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    local trimmed="$(trim "$line")"
    [[ -z "$trimmed" || ${trimmed:0:1} == "#" ]] && continue

    if [[ "$trimmed" == "services:" ]]; then
      continue
    fi

    if [[ "$trimmed" =~ ^-\ name:[[:space:]]*(.+)$ ]]; then
      current="${BASH_REMATCH[1]}"
      service_order+=("$current")
      continue
    fi

    if [[ -n "$current" && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      service_registry["${current}:${key}"]="$(trim "$value")"
    fi
  done < "$MATRIX_FILE"
}

add_service() {
  local name="$1"
  local image_ref="$2"
  local family="$3"
  local os_name="$4"
  local version="$5"
  local variant="$6"
  local profile="$7"
  local enable_ssl="$8"
  local enable_ldap="$9"
  local enable_snmp="${10}"
  local localclient="${11}"
  local build_tool="${12}"

  mkdir -p "$BASE_DIR/$name"

  cat >> "$BASE_DIR/docker-compose.yml" <<EOF
  $name:
    build:
      context: ..
      dockerfile: docker/$name/Dockerfile

EOF

  cat > "$BASE_DIR/$name/Dockerfile" <<EOF
FROM $image_ref

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /src
COPY . /src

ENV PROFILE=$profile
ENV VARIANT=$variant
ENV LOCALCLIENT=$localclient
ENV ENABLE_SSL=$enable_ssl
ENV ENABLE_LDAP=$enable_ldap
ENV ENABLE_SNMP=$enable_snmp
ENV BUILD_TOOL=$build_tool

RUN bash ci/deps/install-apt-packages.sh \
    --family $family \
    --os $os_name \
    --version $version

EOF

  if [[ "$build_tool" == "make" ]]; then
    cat >> "$BASE_DIR/$name/Dockerfile" <<EOF
RUN rm -f Makefile
EOF
  fi

  cat >> "$BASE_DIR/$name/Dockerfile" <<EOF
RUN bash ci/run/docker-build.sh

CMD ["true"]
EOF
}

declare -A platform_catalog
declare -A platform_deps
declare -A binding_profiles
declare -A service_registry
declare -a service_order

parse_platform_catalog
parse_matrix

if [[ ${#service_order[@]} -eq 0 ]]; then
  echo "No services defined in $MATRIX_FILE" >&2
  exit 1
fi

rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"

cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.9"

services:
EOF

for service_name in "${service_order[@]}"; do
  platform_id="${service_registry["${service_name}:platform_id"]:-${service_registry["${service_name}:image"]:-}}"
  if [[ -z "$platform_id" ]]; then
    echo "Service $service_name missing platform_id" >&2
    exit 1
  fi
  base_image="${platform_catalog["${platform_id}:image"]:-}"
  if [[ -z "$base_image" ]]; then
    echo "Platform $platform_id not found for service $service_name" >&2
    exit 1
  fi
  runtime="${platform_catalog["${platform_id}:runtime"]:-docker}"
  if [[ "$runtime" != "docker" ]]; then
    echo "Platform $platform_id for service $service_name is runtime=$runtime (expected docker)" >&2
    exit 1
  fi
  family="${platform_deps["${platform_id}:family"]:-}"
  os_name="${platform_deps["${platform_id}:os"]:-}"
  version="${platform_deps["${platform_id}:version"]:-}"
  if [[ -z "$family" || -z "$os_name" ]]; then
    echo "Platform $platform_id missing deps binding (family/os)" >&2
    exit 1
  fi
  variant="${service_registry["${service_name}:variant"]:-server}"
  profile="${service_registry["${service_name}:profile"]:-packaging}"
  enable_ssl="${service_registry["${service_name}:enable_ssl"]:-${platform_catalog["${platform_id}:enable_ssl"]:-ON}}"
  enable_ldap="${service_registry["${service_name}:enable_ldap"]:-${platform_catalog["${platform_id}:enable_ldap"]:-ON}}"
  enable_snmp="${service_registry["${service_name}:enable_snmp"]:-${platform_catalog["${platform_id}:enable_snmp"]:-ON}}"
  localclient="${service_registry["${service_name}:localclient"]:-${platform_catalog["${platform_id}:localclient"]:-OFF}}"
  build_tool="${service_registry["${service_name}:build_tool"]:-${platform_catalog["${platform_id}:build_tool"]:-cmake}}"

  add_service "$service_name" "$base_image" "$family" "$os_name" "$version" \
    "$variant" "$profile" "$enable_ssl" "$enable_ldap" "$enable_snmp" \
    "$localclient" "$build_tool"
done
