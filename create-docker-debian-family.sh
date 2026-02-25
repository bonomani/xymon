#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
BASE_DIR="${ROOT_DIR}/docker"
MATRIX_FILE="${ROOT_DIR}/ci/deps/docker-matrix.yaml"
PLATFORM_CATALOG_FILE="${ROOT_DIR}/ci/deps/platform-catalog.yaml"
PLATFORM_BINDINGS_FILE="${ROOT_DIR}/ci/deps/platform-deps-bindings.yaml"

if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "Missing matrix definition: $MATRIX_FILE" >&2
  exit 1
fi

if [[ ! -f "$PLATFORM_CATALOG_FILE" ]]; then
  echo "Missing platform catalog: $PLATFORM_CATALOG_FILE" >&2
  exit 1
fi

if [[ ! -f "$PLATFORM_BINDINGS_FILE" ]]; then
  echo "Missing platform deps bindings: $PLATFORM_BINDINGS_FILE" >&2
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
  local current=""
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    local trimmed="$(trim "$line")"
    [[ -z "$trimmed" || ${trimmed:0:1} == "#" ]] && continue

    if [[ "$trimmed" == "platforms:" ]]; then
      continue
    fi

    if [[ "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
      current="${BASH_REMATCH[1]}"
      continue
    fi

    if [[ -n "$current" && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      platform_catalog["${current}:${key}"]="$(trim "$value")"
    fi
  done < "$PLATFORM_CATALOG_FILE"
}

parse_platform_bindings() {
  local section=""
  local current=""
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    local trimmed="$(trim "$line")"
    [[ -z "$trimmed" || ${trimmed:0:1} == "#" ]] && continue

    if [[ "$trimmed" == "binding_profiles:" ]]; then
      section="binding_profiles"
      current=""
      continue
    fi

    if [[ "$trimmed" == "bindings:" ]]; then
      section="bindings"
      current=""
      continue
    fi

    if [[ "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
      current="${BASH_REMATCH[1]}"
      if [[ "${section}" == "bindings" ]]; then
        binding_ids+=("${current}")
      fi
      continue
    fi

    if [[ -n "$current" && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="$(trim "${BASH_REMATCH[2]}")"
      value="$(unquote "${value}")"
      if [[ "${section}" == "binding_profiles" ]]; then
        binding_profiles["${current}:${key}"]="${value}"
      elif [[ "${section}" == "bindings" ]]; then
        platform_bindings["${current}:${key}"]="${value}"
      fi
    fi
  done < "$PLATFORM_BINDINGS_FILE"

  local platform_id=""
  local profile=""
  local field=""
  for platform_id in "${binding_ids[@]}"; do
    profile="${platform_bindings["${platform_id}:profile"]:-}"
    [[ -n "${profile}" ]] || continue

    if [[ -z "${binding_profiles["${profile}:family"]:-}" || -z "${binding_profiles["${profile}:os"]:-}" ]]; then
      echo "Binding profile '${profile}' not found or incomplete for platform '${platform_id}'" >&2
      exit 1
    fi

    for field in family os version; do
      if [[ -z "${platform_bindings["${platform_id}:${field}"]:-}" && -n "${binding_profiles["${profile}:${field}"]:-}" ]]; then
        platform_bindings["${platform_id}:${field}"]="${binding_profiles["${profile}:${field}"]}"
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
  local preset="$7"
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

ENV PRESET=$preset
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
declare -A platform_bindings
declare -A binding_profiles
declare -A service_registry
declare -a binding_ids
declare -a service_order

parse_platform_catalog
parse_platform_bindings
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
  image_id="${service_registry["${service_name}:image"]:-}"
  if [[ -z "$image_id" ]]; then
    echo "Service $service_name missing image reference" >&2
    exit 1
  fi
  base_image="${platform_catalog["${image_id}:image"]:-}"
  if [[ -z "$base_image" ]]; then
    echo "Image id $image_id not found for service $service_name" >&2
    exit 1
  fi
  runtime="${platform_catalog["${image_id}:runtime"]:-docker}"
  if [[ "$runtime" != "docker" ]]; then
    echo "Image id $image_id for service $service_name is runtime=$runtime (expected docker)" >&2
    exit 1
  fi
  family="${platform_bindings["${image_id}:family"]:-}"
  os_name="${platform_bindings["${image_id}:os"]:-}"
  version="${platform_bindings["${image_id}:version"]:-}"
  if [[ -z "$family" || -z "$os_name" ]]; then
    echo "Image id $image_id missing deps binding (family/os)" >&2
    exit 1
  fi
  variant="${service_registry["${service_name}:variant"]:-server}"
  preset="${service_registry["${service_name}:preset"]:-packaging}"
  enable_ssl="${service_registry["${service_name}:enable_ssl"]:-${platform_catalog["${image_id}:enable_ssl"]:-ON}}"
  enable_ldap="${service_registry["${service_name}:enable_ldap"]:-${platform_catalog["${image_id}:enable_ldap"]:-ON}}"
  enable_snmp="${service_registry["${service_name}:enable_snmp"]:-${platform_catalog["${image_id}:enable_snmp"]:-ON}}"
  localclient="${service_registry["${service_name}:localclient"]:-${platform_catalog["${image_id}:localclient"]:-OFF}}"
  build_tool="${service_registry["${service_name}:build_tool"]:-${platform_catalog["${image_id}:build_tool"]:-cmake}}"

  add_service "$service_name" "$base_image" "$family" "$os_name" "$version" \
    "$variant" "$preset" "$enable_ssl" "$enable_ldap" "$enable_snmp" \
    "$localclient" "$build_tool"
done
