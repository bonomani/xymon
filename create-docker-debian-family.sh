#!/bin/sh
set -e

BASE_DIR="docker"

mkdir -p "$BASE_DIR"

cat > "$BASE_DIR/docker-compose.yml" <<'EOF'
version: "3.9"

services:
EOF

add_os() {
  NAME="$1"
  IMAGE="$2"

  mkdir -p "$BASE_DIR/$NAME"

  cat >> "$BASE_DIR/docker-compose.yml" <<EOF
  $NAME:
    build:
      context: ..
      dockerfile: docker/$NAME/Dockerfile

EOF

  cat > "$BASE_DIR/$NAME/Dockerfile" <<EOF
FROM $IMAGE

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \\
    build-essential \\
    cmake \\
    pkg-config \\
    perl \\
    fping \\
    ca-certificates \\
    libssl-dev \\
    libldap2-dev \\
    librrd-dev \\
    libpcre3-dev \\
    libc-ares-dev \\
    libsnmp-dev \\
    libtirpc-dev \\
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

ENV PRESET=packaging
ENV VARIANT=server
ENV LOCALCLIENT=OFF
ENV ENABLE_SSL=ON
ENV ENABLE_LDAP=ON
ENV ENABLE_SNMP=ON

RUN bash ci/run/cmake-configure.sh
RUN bash ci/run/cmake-build.sh

CMD ["true"]
EOF
}

add_os debian-bullseye debian:bullseye
add_os debian-bookworm debian:bookworm
add_os debian-trixie debian:trixie
add_os ubuntu-22.04 ubuntu:22.04
add_os ubuntu-24.04 ubuntu:24.04

