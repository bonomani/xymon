FROM debian:12.13-slim

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /src
COPY . /src

ENV PRESET=packaging
ENV VARIANT=server
ENV LOCALCLIENT=OFF
ENV ENABLE_SSL=ON
ENV ENABLE_LDAP=ON
ENV ENABLE_SNMP=ON

RUN bash ci/deps/install-apt-packages.sh     --family debian     --os debian     --version bookworm

RUN bash ci/run/cmake-configure.sh
RUN bash ci/run/cmake-build.sh

CMD ["true"]
