<img src="https://upstreamyard.github.io/helm-charts/logo.png" alt="upstreamyard logo" width="120" align="right">

# Fineract Docker image (Apache Fineract 1.16)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Production-ready, multi-arch (`amd64`, `arm64`) and signed **Apache Fineract Docker image**, with a **version tag for every Apache Fineract release**, built from the signed Apache binary release. Fineract's own image has had no version tags since 1.12.1, and its `latest` tag is an unreleased development build. This image is **secure by default**: `FINERACT_ADMIN_PASSWORD` replaces the default `mifos`/`password` login, every container gets its own TLS certificate instead of the public built-in one, and it runs as non-root with a healthcheck. **PostgreSQL and MariaDB** drivers are included, **document uploads work** and persist in a volume, and the image runs as read, write or batch instance for **high availability and scaling**. Use it with Docker Compose, or on Kubernetes with our **[Fineract Helm chart](https://github.com/upstreamyard/helm-charts/tree/main/charts/fineract)**.

> Community-maintained by **upstreamyard**. This is not an official Apache Fineract image. Apache Fineract is licensed under Apache-2.0 (see [Licences](#licences)). Apache, Apache Fineract and Fineract are trademarks of the Apache Software Foundation.

| Registry | Image |
|---|---|
| Docker Hub | `upstreamyard/fineract` |
| GitHub Container Registry | `ghcr.io/upstreamyard/fineract` |

| Tag | Follows | Java |
|---|---|---|
| `1.16.1`, `1.16`, `latest` | Apache Fineract 1.16.x, the current release | Eclipse Temurin 25 |

New Fineract releases are built within 24 hours of appearing on Apache's download server. Pin `1.16` to get patch releases automatically; pin `1.16.1` to control database migrations yourself.

## Why this Fineract image

Compared with Fineract's own `apache/fineract` image. We tested its `latest` tag on 2026-10-31.

| | `apache/fineract:latest` | `upstreamyard/fineract` |
|---|---|---|
| Version tags | none since `1.12.1` (Sept 2025); `latest` is `1.17.0-SNAPSHOT`, the development branch | every release: `1.16.1`, `1.16`, `latest` |
| Built from | the development branch, by Fineract's CI | the signed Apache binary release (SHA-512 and GPG checked) |
| Login `mifos` / `password` | stays until you change it | replaced on the first start with `FINERACT_ADMIN_PASSWORD` |
| HTTPS certificate | built-in keystore whose private key is public (Fineract's source code) | generated per container; or your own keystore |
| Document and image uploads | fail with HTTP 500 (`ContentStoreException: /.fineract`) | stored in `/var/lib/fineract` (volume) |
| JVM options (`-Duser.timezone=UTC`, …) | passed after the main class, so ignored | applied |
| Heap | Java default: 25% of the memory limit | 60% of the memory limit |
| MariaDB driver | not included | included (MariaDB Connector/J 3.5.11) |
| Healthcheck | none | built in (readiness endpoint) |
| Runs as | `nobody` (UID 65534) | non-root UID `10001`; read-only root filesystem supported |
| Signed, SBOM, provenance | no | cosign, SBOM, SLSA provenance |
| Helm chart | none | [upstreamyard/fineract](https://github.com/upstreamyard/helm-charts/tree/main/charts/fineract) |

Both stop cleanly on `SIGTERM` within about 2 seconds.

## At a glance

| | |
|---|---|
| Ports | `8443` HTTPS (default), `8080` HTTP with `FINERACT_SERVER_SSL_ENABLED=false` |
| API | `https://<host>:8443/fineract-provider/api/v1`, header `Fineract-Platform-TenantId: default`, HTTP basic auth |
| Probes | `/fineract-provider/actuator/health/liveness` and `/readiness`; the image's `HEALTHCHECK` uses readiness |
| Metrics | Prometheus: `/fineract-provider/actuator/prometheus` (no login, same port) |
| Requires | PostgreSQL (tested: 18), MariaDB (tested: 11.8) or MySQL (tested: 8.4, driver not included). Two databases must exist: `fineract_tenants` and `fineract_default` |
| Storage | `/var/lib/fineract`: uploaded documents and images. Mount a volume, or use S3 |
| Config | environment variables (`FINERACT_*`) |
| Runs as | UID/GID `10001`. With a read-only root filesystem, `/tmp` must be writable |
| First start | about 30–150 s: Fineract creates its tables (Liquibase) |
| Shutdown | `SIGTERM` stops Fineract cleanly (exit code 143) |

**AI agents and coding assistants:** read [`AGENTS.md`](https://github.com/upstreamyard/fineract/blob/main/AGENTS.md) for deployment rules, and [`llms.txt`](https://github.com/upstreamyard/fineract/blob/main/llms.txt) for an index of all docs.

## Quick start: run Fineract in Docker

[`docker-compose.yml`](https://github.com/upstreamyard/fineract/blob/main/docker-compose.yml) starts Fineract with PostgreSQL 18. Change the `change-me` values, then:

```bash
docker compose up -d
docker compose logs -f fineract   # wait for "replaced the default password of user mifos"
curl -k -u 'mifos:Change-me-4dm1n!' -H 'Fineract-Platform-TenantId: default' \
  https://localhost:8443/fineract-provider/api/v1/offices
```

The answer lists the "Head Office". Swagger UI: https://localhost:8443/fineract-provider/swagger-ui/index.html. Fineract is an API server; for a web UI, run the separate [Mifos X web app](https://github.com/openMF/web-app) against it.

MariaDB instead: [`examples/mariadb/docker-compose.yml`](https://github.com/upstreamyard/fineract/blob/main/examples/mariadb/docker-compose.yml).

## Configuration

### Environment variables

The most important settings. All other Fineract settings work as documented in Fineract's [configuration reference](https://fineract.apache.org/docs/stable/#_appendix_a_properties_and_environment_variables) (`FINERACT_*` variables).

| Variable | Default | Description |
|---|---|---|
| `FINERACT_HIKARI_JDBC_URL` | `jdbc:postgresql://localhost:5432/fineract_tenants` | Tenant store database |
| `FINERACT_HIKARI_USERNAME`, `FINERACT_HIKARI_PASSWORD` | `root`, `postgres` | Its login |
| `FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME` | `org.postgresql.Driver` | `org.mariadb.jdbc.Driver` for MariaDB |
| `FINERACT_DEFAULT_TENANTDB_HOSTNAME`, `_PORT`, `_NAME` | `localhost`, `5432`, `fineract_default` | Database of the default tenant |
| `FINERACT_DEFAULT_TENANTDB_UID`, `_PWD` | `root`, `postgres` | Its login |
| `FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD` | `fineract` | Encrypts the tenant's database password in the tenant store. **Set it before the first start and never change it**: with another value Fineract exits with `Invalid master password` |
| `FINERACT_DEFAULT_TENANTDB_TIMEZONE` | `Asia/Kolkata` | Time zone of the default tenant, stored on the first start |
| `FINERACT_ADMIN_PASSWORD` | – | Replaces the password of user `mifos` once Fineract is ready, but only while it is still `password` (write instances only). Must meet Fineract's password policy: 12–50 characters with upper and lower case, a digit and a special character, no spaces, no character twice in a row |
| `FINERACT_SERVER_SSL_ENABLED` | `true` | `false`: plain HTTP, e.g. behind a TLS-terminating proxy |
| `FINERACT_SERVER_PORT` | `8443`, or `8080` without TLS | Listening port |
| `FINERACT_SERVER_SSL_CERTIFICATE`, `_CERTIFICATE_PRIVATE_KEY` | – | PEM certificate and key files, e.g. from a Kubernetes TLS Secret. Reloaded when the files change (this image) |
| `FINERACT_SERVER_SSL_KEY_STORE`, `_PASSWORD` | generated | Your own keystore (PKCS12 or JKS), e.g. `/etc/fineract/tls/keystore.p12` |
| `FINERACT_MODE_READ_ENABLED`, `_WRITE_ENABLED`, `_BATCH_MANAGER_ENABLED`, `_BATCH_WORKER_ENABLED` | `true` | Instance type, see [Scaling](#scaling-and-high-availability) |
| `FINERACT_LIQUIBASE_ENABLED` | `true` | Database migrations at start |
| `FINERACT_NODE_ID` | `1` | Scheduled jobs are stored for node `1`: keep `1` on the instance that runs jobs |
| `FINERACT_CONTENT_FILESYSTEM_ROOT_FOLDER` | `/var/lib/fineract` | Uploaded documents and images (Fineract's default `~/.fineract`) |
| `FINERACT_LOGGING_JSON_ENABLED` | `false` | `true`: one JSON object per log line |
| `FINERACT_LOGGING_LEVEL` | `INFO` | Log level of `org.apache.fineract` |
| `JAVA_OPTS_MEMORY` | `-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=60.0` | Heap options |
| `JAVA_OPTS` | – | Extra Java options, added after ours |

Every `FINERACT_*` variable also has a `_FILE` variant that reads the value from a file, e.g. `FINERACT_HIKARI_PASSWORD_FILE=/run/secrets/db-password` for Docker or Kubernetes secrets.

Set a memory limit of at least 2 GiB: right after the start Fineract uses about 1.5 GiB.

### Databases

Fineract needs two databases before its first start: the tenant store (`fineract_tenants`) and the default tenant (`fineract_default`), both owned by the database user Fineract logs in with. It creates all tables itself. The Compose files above create both databases with an init script.

- **PostgreSQL**: the default. Tested with PostgreSQL 18.
- **MariaDB**: driver included. Start MariaDB with `--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-snapshot-isolation=OFF` (Fineract's own MariaDB settings), set `FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME=org.mariadb.jdbc.Driver`, a `jdbc:mariadb://` URL and `FINERACT_DEFAULT_TENANTDB_PORT=3306`. Tested with MariaDB 11.8.
- **MySQL**: the MySQL driver is GPL-licensed and not included. Mount [MySQL Connector/J](https://central.sonatype.com/artifact/com.mysql/mysql-connector-j) into `/app/plugins` (see [Extending](#extending-the-image)) and use `com.mysql.cj.jdbc.Driver` with a `jdbc:mysql://` URL. Tested with MySQL 8.4 and Connector/J 9.7.0.

### HTTPS

Fineract serves HTTPS on port 8443 by default. Its built-in keystore is the same for every installation and its private key is public, so this image generates a self-signed certificate for each container at start instead (EC P-256, valid for `localhost`, `127.0.0.1` and the container hostname). Clients still have to accept a self-signed certificate. For production, either:

- mount a certificate and key in PEM format, e.g. a Kubernetes TLS Secret from cert-manager, and set `FINERACT_SERVER_SSL_CERTIFICATE` and `FINERACT_SERVER_SSL_CERTIFICATE_PRIVATE_KEY` to the two file paths. Fineract picks up a renewed certificate within seconds, without a restart (tested with RSA keys in PKCS#1 format, cert-manager's default);
- mount your own keystore and set `FINERACT_SERVER_SSL_KEY_STORE` and `FINERACT_SERVER_SSL_KEY_STORE_PASSWORD`; or
- terminate TLS in front of Fineract (load balancer, ingress) and set `FINERACT_SERVER_SSL_ENABLED=false`.

Fineract's documentation lists `FINERACT_SERVER_SSL_PROTOCOLS` and `FINERACT_SERVER_SSL_CIPHERS`, but Fineract 1.16.1 ignores them.

### Admin password

Every new Fineract tenant has a superuser `mifos` with the password `password`. With `FINERACT_ADMIN_PASSWORD`, the container logs in as `mifos` once Fineract is ready and sets the new password. Until then, which takes a few seconds after the readiness probe succeeds, the old password works. Once the password has changed, the variable has no further effect, so change it later through Fineract's API or UI. Without the variable, the container logs a warning on every start while `mifos` still has the default password.

## Scaling and high availability

Fineract's instance types let one database serve several containers:

| Instance | Settings | Tested behaviour |
|---|---|---|
| All in one (default) | – | everything |
| Read | `FINERACT_MODE_WRITE_ENABLED=false`, `FINERACT_MODE_BATCH_MANAGER_ENABLED=false`, `FINERACT_MODE_BATCH_WORKER_ENABLED=false` | `GET` answered, writes and job APIs return `405` |
| Batch | `FINERACT_MODE_READ_ENABLED=false`, `FINERACT_MODE_WRITE_ENABLED=false` | job APIs answered, other APIs return `405` |

- Only one instance should run database migrations: run the image once with `SPRING_PROFILES_ACTIVE=liquibase-only` (migrates and exits with code 0), and start the servers with `FINERACT_LIQUIBASE_ENABLED=false`.
- Fineract's documentation names these variables `FINERACT_READ_MODE_ENABLED` etc.; Fineract 1.16.1 reads `FINERACT_MODE_READ_ENABLED` etc., as shown above.
- Without read replica settings (`FINERACT_DEFAULT_TENANTDB_RO_*`), a read instance uses the tenant's normal database connection (tested). We haven't tested read replicas.
- Separate batch manager and worker instances exchange work through JMS or Kafka (`FINERACT_REMOTE_JOB_MESSAGE_HANDLER_*`); we haven't tested that split.
- Uploaded documents must be on storage that all write instances share. Fineract can also store them in S3 (`FINERACT_CONTENT_S3_*`); we haven't tested that.

## Kubernetes and Helm: Fineract Helm chart

The recommended way to run Fineract on Kubernetes is our Helm chart ([`upstreamyard/helm-charts`](https://github.com/upstreamyard/helm-charts/tree/main/charts/fineract)): a migration Job, write, read and batch instances, Secrets for all passwords and a ServiceMonitor.

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install fineract upstreamyard/fineract -f my-values.yaml
```

Running the image yourself:

1. Run migrations in a Job with `SPRING_PROFILES_ACTIVE=liquibase-only`, and set `FINERACT_LIQUIBASE_ENABLED=false` on the Deployments.
2. Pass passwords from a Secret (`env.valueFrom.secretKeyRef` or the `_FILE` variants).
3. Probes: `httpGet` on `/fineract-provider/actuator/health/liveness` and `/readiness`, port 8443 with `scheme: HTTPS`, or 8080 with `FINERACT_SERVER_SSL_ENABLED=false`. Use a `startupProbe` that allows a few minutes.
4. Set a memory limit of at least 2 GiB; the heap is 60% of it.
5. The container works with `runAsNonRoot: true`, `readOnlyRootFilesystem: true` (plus an `emptyDir` at `/tmp`) and all capabilities dropped.

## Migrating to this image

**From `apache/fineract`:** the environment variables are the same, so keep them.

- The container runs as UID `10001` instead of `nobody`. Files you mount must be readable by it.
- Documents now go to `/var/lib/fineract`. In Fineract's image they could not be stored at all.
- **If you ran `apache/fineract:latest`**: your database already contains changes from Fineract's development branch (15 more migrations than 1.16.1 on 2026-10-31). In our test, 1.16.1 started on such a database and answered API calls, but Fineract doesn't support going back to an older version. Try it on a copy of your database first, or wait for the next release.

## Extending the image

Jars in `/app/plugins` are added to Fineract's classpath, e.g. JDBC drivers or Fineract plugins:

```bash
docker run -v "$PWD/plugins:/app/plugins:ro" ... upstreamyard/fineract:1.16
```

Or build your own image:

```dockerfile
FROM upstreamyard/fineract:1.16
ADD --chmod=644 https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/9.7.0/mysql-connector-j-9.7.0.jar /app/plugins/
```

## FAQ

**How do I run Fineract in Docker?** Use the [quick start](#quick-start-run-fineract-in-docker): Fineract plus PostgreSQL in one Compose file.

**Is there a Helm chart for Fineract?** Yes: [`upstreamyard/fineract`](https://github.com/upstreamyard/helm-charts/tree/main/charts/fineract). Fineract's own documentation has a "Helm Charts" page that says "TBD".

**Which tag should I use?** `1.16` for the current release with its patch releases. Fineract's own `apache/fineract:latest` is a development build, not a release.

**What is the default Fineract login?** User `mifos`, password `password`, tenant `default`. Set `FINERACT_ADMIN_PASSWORD` so it is replaced on the first start.

**Why do I get `Invalid master password`?** `FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD` differs from the value used on the first start. Set the original value again.

**How do I run Fineract highly available?** Several write instances on one database, migrations in a separate run, documents in S3 or on shared storage; see [Scaling](#scaling-and-high-availability) and the Helm chart.

**How do I monitor Fineract with Prometheus?** Scrape `/fineract-provider/actuator/prometheus` on the API port.

**Where is the web UI?** Fineract is the API server. The [Mifos X web app](https://github.com/openMF/web-app) is a separate project that runs in front of it.

## Verifying images

Images are signed keylessly with [cosign](https://github.com/sigstore/cosign) and include an SBOM and SLSA provenance:

```bash
cosign verify upstreamyard/fineract:1.16 \
  --certificate-identity-regexp '^https://github.com/upstreamyard/fineract/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
docker buildx imagetools inspect upstreamyard/fineract:1.16 --format '{{ json .SBOM }}'
```

## How it's built

[`.github/workflows/build.yml`](https://github.com/upstreamyard/fineract/blob/main/.github/workflows/build.yml) finds the release Apache currently lists on its download server. [`scripts/fetch-release.sh`](https://github.com/upstreamyard/fineract/blob/main/scripts/fetch-release.sh) downloads the official binary release, checks its SHA-512 and its GPG signature against the Fineract KEYS file, and takes the executable `fineract-provider` jar and the licence files from it. CI then builds the [`Dockerfile`](https://github.com/upstreamyard/fineract/blob/main/Dockerfile) for amd64 and arm64.

- **Java:** Eclipse Temurin JRE, the version the release was compiled for (Java 25 for 1.16). Base: Ubuntu 24.04.
- **Added:** MariaDB Connector/J 3.5.11 (Maven Central, pinned by SHA-256), `tini`, `curl`.
- **Changed:** nothing inside Fineract. The [entrypoint](https://github.com/upstreamyard/fineract/blob/main/docker-entrypoint.sh) sets Java options, generates the TLS certificate and sets the admin password.
- **Testing:** before publishing, [`scripts/smoke-test.sh`](https://github.com/upstreamyard/fineract/blob/main/scripts/smoke-test.sh) checks:
  - the first start on PostgreSQL 18 and on MariaDB 11.8;
  - the admin password and the generated certificate;
  - a document upload that survives a restart, Prometheus metrics and a clean stop;
  - a `liquibase-only` run, then HTTP, `_FILE` secrets and a read-only root filesystem;
  - read and batch instances, and a PEM certificate that is replaced while Fineract runs;
  - that a changed master password is refused.

## Licences

| Component | Licence | Licence text in the image | Source code |
|---|---|---|---|
| Apache Fineract | Apache-2.0 | `/licenses/fineract/` (LICENSE, NOTICE and the licences of its bundled libraries) | [apache/fineract](https://github.com/apache/fineract) at tag `<version>` |
| MariaDB Connector/J | LGPL-2.1-or-later | `/licenses/mariadb-jdbc/` | [mariadb-corporation/mariadb-connector-j](https://github.com/mariadb-corporation/mariadb-connector-j) |
| Ubuntu packages, Eclipse Temurin | various, incl. GPL | `/usr/share/doc/*/copyright`, `/opt/java/openjdk/legal/` | Ubuntu and Adoptium source archives |
| Our packaging (Dockerfile, scripts) | Apache-2.0 | – | this repository |

## Support

Issues with the image: [open an issue here](https://github.com/upstreamyard/fineract/issues). Questions about using Fineract: [Fineract's mailing lists and chat](https://fineract.apache.org/#contribute).
