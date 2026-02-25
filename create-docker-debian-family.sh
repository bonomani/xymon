#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
BASE_DIR="${ROOT_DIR}/docker"
MATRIX_FILE="${ROOT_DIR}/ci/deps/docker-matrix.yaml"
IMAGES_FILE="${ROOT_DIR}/ci/deps/docker-images.yaml"

if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "Missing matrix definition: $MATRIX_FILE" >&2
  exit 1
fi

if [[ ! -f "$IMAGES_FILE" ]]; then
  echo "Missing image registry: $IMAGES_FILE" >&2
  exit 1
fi

trim() {
  local val="$1"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

parse_images() {
  local current=""
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    local trimmed="$(trim "$line")"
    [[ -z "$trimmed" || ${trimmed:0:1} == "#" ]] && continue

    if [[ "$trimmed" == "images:" ]]; then
      continue
    fi

    if [[ "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
      current="${BASH_REMATCH[1]}"
      continue
    fi

    if [[ -n "$current" && "$trimmed" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      image_registry["${current}:${key}"]="$(trim "$value")"
    fi
  done < "$IMAGES_FILE"
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

declare -A image_registry
declare -A service_registry
declare -a service_order

parse_images
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
  base_image="${image_registry["${image_id}:image"]:-}"
  if [[ -z "$base_image" ]]; then
    echo "Image id $image_id not found for service $service_name" >&2
    exit 1
  fi
  family="${image_registry["${image_id}:family"]:-}"
  os_name="${image_registry["${image_id}:os"]:-}"
  version="${image_registry["${image_id}:version"]:-}"
  variant="${service_registry["${service_name}:variant"]:-server}"
  preset="${service_registry["${service_name}:preset"]:-packaging}"
  enable_ssl="${service_registry["${service_name}:enable_ssl"]:-${image_registry["${image_id}:enable_ssl"]:-ON}}"
  enable_ldap="${service_registry["${service_name}:enable_ldap"]:-${image_registry["${image_id}:enable_ldap"]:-ON}}"
  enable_snmp="${service_registry["${service_name}:enable_snmp"]:-${image_registry["${image_id}:enable_snmp"]:-ON}}"
  localclient="${service_registry["${service_name}:localclient"]:-${image_registry["${image_id}:localclient"]:-OFF}}"
  build_tool="${service_registry["${service_name}:build_tool"]:-${image_registry["${image_id}:build_tool"]:-cmake}}"

  add_service "$service_name" "$base_image" "$family" "$os_name" "$version" \
    "$variant" "$preset" "$enable_ssl" "$enable_ldap" "$enable_snmp" \
    "$localclient" "$build_tool"
done
