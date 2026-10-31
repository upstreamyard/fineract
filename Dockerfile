# syntax=docker/dockerfile:1.7
# Container image for Apache Fineract (https://github.com/apache/fineract)
# Maintained by upstreamyard. Packages the official Apache binary release (the executable
# fineract-provider jar), unpacked into ./upstream by CI after checking its SHA-512 and
# GPG signature, plus the MariaDB JDBC driver (Fineract bundles only the PostgreSQL one).

# CI passes the Java version the release was compiled for (scripts/fetch-release.sh).
ARG JAVA_VERSION=25

# -----------------------------
# Prepare: release files, extras, licences
# -----------------------------
# Only handles platform-independent files (jars, texts), so it runs natively.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS prepare

# MariaDB Connector/J (LGPL-2.1-or-later), from Maven Central, and its licence text.
ARG MARIADB_JDBC_VERSION=3.5.11
ARG MARIADB_JDBC_SHA256=42604178b9e57ec08ee0035079961516f086e455d0141f0b22c6eff29fb2fff4
ARG MARIADB_JDBC_LICENSE_SHA256=c8cfa082f122323774057c2808eb7e796703bde9459fa04ff6f2c9cc25f74eff

COPY upstream/fineract-provider.jar /app/fineract-provider.jar
COPY upstream/LICENSE upstream/NOTICE /licenses/fineract/
COPY upstream/licenses/ /licenses/fineract/licenses/
ADD --chmod=644 --checksum=sha256:${MARIADB_JDBC_SHA256} \
    https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/${MARIADB_JDBC_VERSION}/mariadb-java-client-${MARIADB_JDBC_VERSION}.jar \
    /app/lib/
ADD --chmod=644 --checksum=sha256:${MARIADB_JDBC_LICENSE_SHA256} \
    https://raw.githubusercontent.com/mariadb-corporation/mariadb-connector-j/${MARIADB_JDBC_VERSION}/LICENSE \
    /licenses/mariadb-jdbc/LICENSE
RUN chmod -R a+rX /app /licenses && mkdir -p /app/plugins

# -----------------------------
# Runtime
# -----------------------------
FROM eclipse-temurin:${JAVA_VERSION}-jre-noble AS final

ARG FINERACT_VERSION=unknown

RUN apt-get update && apt-get install -y --no-install-recommends tini curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 fineract \
    && useradd --system --uid 10001 --gid fineract --home-dir /var/lib/fineract --no-create-home fineract \
    && mkdir -p /var/lib/fineract \
    && chown fineract:fineract /var/lib/fineract

COPY --from=prepare /licenses/ /licenses/
COPY --from=prepare /app/ /app/
COPY docker-entrypoint.sh healthcheck /usr/local/bin/

# Uploaded documents and images go to /var/lib/fineract (mount a volume there). Fineract's
# own default is ~/.fineract, which is not writable in Fineract's official image.
ENV FINERACT_HOME=/app \
    FINERACT_CONTENT_FILESYSTEM_ROOT_FOLDER=/var/lib/fineract

WORKDIR /app

LABEL org.opencontainers.image.title="fineract" \
      org.opencontainers.image.description="Apache Fineract core banking server: versioned releases, non-root, healthcheck, MariaDB and PostgreSQL drivers. Community image by upstreamyard, not an official Apache image." \
      org.opencontainers.image.version="${FINERACT_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND LGPL-2.1-or-later" \
      org.opencontainers.image.vendor="upstreamyard" \
      org.opencontainers.image.url="https://github.com/upstreamyard/fineract" \
      org.opencontainers.image.documentation="https://github.com/upstreamyard/fineract#readme"

# HTTPS (Fineract's default), HTTP when FINERACT_SERVER_SSL_ENABLED=false
EXPOSE 8443 8080

# A first start on an empty database runs all migrations; allow for slow machines.
HEALTHCHECK --interval=15s --timeout=5s --start-period=300s --retries=3 CMD ["healthcheck"]

USER 10001:10001

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
