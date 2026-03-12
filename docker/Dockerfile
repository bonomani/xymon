ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG BUILD_TOOL

ENV DEBIAN_FRONTEND=noninteractive
ENV BUILD_TOOL=${BUILD_TOOL}

WORKDIR /src
COPY . /src

RUN if command -v dnf >/dev/null 2>&1; then \
      :; \
    elif command -v microdnf >/dev/null 2>&1; then \
      microdnf install -y dnf && microdnf clean all; \
    fi

RUN if command -v bash >/dev/null 2>&1; then \
      :; \
    elif command -v apk >/dev/null 2>&1; then \
      apk add --no-cache bash; \
    else \
      echo "Base image is missing bash and no supported bootstrap package manager was found." >&2; \
      exit 1; \
    fi

RUN bash ci/deps/install-default-packages.sh --build-tool "${BUILD_TOOL}"

RUN if [ "${BUILD_TOOL}" = "make" ]; then rm -f Makefile; fi \
    && bash ci/run/docker-build.sh

CMD ["true"]
