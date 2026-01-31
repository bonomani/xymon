FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    perl \
    fping \
    ca-certificates \
    libssl-dev \
    libldap2-dev \
    librrd-dev \
    libpcre3-dev \
    libsnmp-dev \
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
