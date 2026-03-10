FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /src
COPY . /src

ENV PROFILE=packaging
ENV VARIANT=server
ENV LOCALCLIENT=OFF
ENV ENABLE_SSL=ON
ENV ENABLE_LDAP=ON
ENV ENABLE_SNMP=ON
ENV BUILD_TOOL=cmake

RUN bash ci/deps/install-apt-packages.sh     --family ubuntu     --os ubuntu     --version latest

RUN bash ci/run/docker-build.sh

CMD ["true"]
