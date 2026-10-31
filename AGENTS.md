# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or deploying the image it publishes: a Docker image of Apache Fineract, the core banking API server.

## Image facts

| Key | Value |
|---|---|
| Image | `upstreamyard/fineract` (Docker Hub), `ghcr.io/upstreamyard/fineract` |
| Tags | `<version>` (e.g. `1.16.1`), `<major>.<minor>` (`1.16`), `latest` (= current Apache release) |
| Platforms | `linux/amd64`, `linux/arm64` |
| Java | Eclipse Temurin JRE 25 (the version the release was compiled for) |
| Ports | `8443` HTTPS (default, self-signed certificate generated per container), `8080` HTTP with `FINERACT_SERVER_SSL_ENABLED=false` |
| API | `/fineract-provider/api/v1`, header `Fineract-Platform-TenantId: default`, HTTP basic auth |
| Probes | `/fineract-provider/actuator/health/liveness`, `/fineract-provider/actuator/health/readiness` (HTTPS on 8443 or HTTP on 8080); built-in `HEALTHCHECK` uses readiness |
| Metrics | `/fineract-provider/actuator/prometheus`, no login |
| Databases | PostgreSQL (driver in Fineract), MariaDB (driver added in `/app/lib`), MySQL (driver not included; mount it in `/app/plugins`) |
| Data | `/var/lib/fineract`: uploaded documents and images |
| User | non-root, UID/GID `10001`; read-only root filesystem works with a writable `/tmp` |
| Config | env vars `FINERACT_*` (Fineract's own), each with a `_FILE` variant; `FINERACT_ADMIN_PASSWORD`, `FINERACT_SERVER_SSL_CERTIFICATE`, `FINERACT_SERVER_SSL_CERTIFICATE_PRIVATE_KEY`, `JAVA_OPTS_MEMORY`, `JAVA_OPTS` (this image) |
| Fineract project | https://github.com/apache/fineract (Apache-2.0) |

## Deploying the image

Rules that avoid the common failures:

- **Databases first:** two databases must exist before the first start, `fineract_tenants` (`FINERACT_HIKARI_JDBC_URL`) and `fineract_default` (`FINERACT_DEFAULT_TENANTDB_HOSTNAME`/`_NAME`), owned by the login Fineract uses (`FINERACT_HIKARI_USERNAME`/`_PASSWORD` and `FINERACT_DEFAULT_TENANTDB_UID`/`_PWD`). Fineract creates the tables.
- **Master password:** set `FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD` before the first start and never change it; another value makes Fineract exit with `Invalid master password on tenant connection 1`. `FINERACT_DEFAULT_MASTER_PASSWORD` has no effect while the tenant variable is set (it always is, default `fineract`).
- **Tenant time zone:** `FINERACT_DEFAULT_TENANTDB_TIMEZONE` is stored on the first start; Fineract's default is `Asia/Kolkata`.
- **Admin password:** set `FINERACT_ADMIN_PASSWORD` (12–50 characters, upper and lower case, digit, special character, no spaces, no character twice in a row). The container replaces `mifos`/`password` once Fineract is ready, only while the password is still the default, only on write instances. Later changes go through Fineract's API.
- **MariaDB:** `FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME=org.mariadb.jdbc.Driver`, `jdbc:mariadb://` URL, `FINERACT_DEFAULT_TENANTDB_PORT=3306`; start MariaDB with `--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-snapshot-isolation=OFF`.
- **TLS:** for production, mount PEM files (e.g. a cert-manager TLS Secret) and set `FINERACT_SERVER_SSL_CERTIFICATE` and `FINERACT_SERVER_SSL_CERTIFICATE_PRIVATE_KEY` (reloaded on change, no restart), or mount a keystore and set `FINERACT_SERVER_SSL_KEY_STORE` and `_PASSWORD`, or terminate TLS in front and set `FINERACT_SERVER_SSL_ENABLED=false` (port becomes 8080). `FINERACT_SERVER_SSL_PROTOCOLS` and `_CIPHERS` are ignored by Fineract 1.16.1.
- **Several instances:** run migrations once with `SPRING_PROFILES_ACTIVE=liquibase-only` (exits 0), then servers with `FINERACT_LIQUIBASE_ENABLED=false`. Instance types use `FINERACT_MODE_READ_ENABLED`, `FINERACT_MODE_WRITE_ENABLED`, `FINERACT_MODE_BATCH_MANAGER_ENABLED`, `FINERACT_MODE_BATCH_WORKER_ENABLED` (not the `FINERACT_READ_MODE_ENABLED` names in Fineract's docs). Keep `FINERACT_NODE_ID=1` on the instance that runs scheduled jobs. Documents must be on shared storage across write instances.
- **Probes:** a first start on an empty database takes 30–150 s; use a startup probe with a few minutes of budget. With HTTPS, Kubernetes probes need `scheme: HTTPS`.
- **Memory:** limit at least 2 GiB; the heap is 60% of the limit (`JAVA_OPTS_MEMORY`). `JAVA_OPTS` is appended to our Java options.
- **Shutdown:** `SIGTERM` stops Fineract cleanly in about 2 s (exit 143); allow 30 s of grace period.
- **Never** set `SPRING_PROFILES_ACTIVE=test` in production: it enables insecure test endpoints.

Ready-to-use manifests:

- Docker Compose with PostgreSQL 18: [`docker-compose.yml`](docker-compose.yml)
- Docker Compose with MariaDB 11.8: [`examples/mariadb/docker-compose.yml`](examples/mariadb/docker-compose.yml)
- Kubernetes: Helm chart `upstreamyard/fineract` from `https://upstreamyard.github.io/helm-charts` (also `oci://ghcr.io/upstreamyard/charts/fineract`), documented in https://github.com/upstreamyard/helm-charts/tree/main/charts/fineract

Verify a deployment:

```bash
curl -k -u 'mifos:<FINERACT_ADMIN_PASSWORD>' -H 'Fineract-Platform-TenantId: default' \
  https://<host>:8443/fineract-provider/api/v1/offices
```

## Working on this repository

Layout:

- `Dockerfile`: packages the `fineract-provider` jar from the official binary release, which `scripts/fetch-release.sh` downloads, verifies (SHA-512 and GPG) and unpacks into `./upstream/` (git-ignored), plus the MariaDB driver pinned by version and SHA-256
- `scripts/fetch-release.sh`: also writes `upstream/JAVA_VERSION` (from the class file version), which CI passes as `JAVA_VERSION`
- `docker-entrypoint.sh`: `_FILE` variables, PEM certificates through a reloading Spring SSL bundle, TLS certificate generation, port default, Java options, background job that replaces the default `mifos` password
- `healthcheck`: curl on the readiness endpoint with the same port and scheme rules as the entrypoint
- `scripts/smoke-test.sh`: the test CI runs before publishing; run it locally too
- `.github/workflows/build.yml`: builds the release listed on Apache's download server, smoke-tests, pushes multi-arch, signs and syncs the Docker Hub README

Build and test locally:

```bash
scripts/fetch-release.sh 1.16.1
docker build -t fineract:dev --build-arg FINERACT_VERSION=1.16.1 --build-arg JAVA_VERSION=$(cat upstream/JAVA_VERSION) .
scripts/smoke-test.sh fineract:dev
```

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Do not modify Fineract's jar or its configuration files; packaging changes go into the Dockerfile and the entrypoint. Report Fineract bugs to the user rather than filing them.
- **MariaDB driver:** to update it, change the version and both SHA-256 `ARG`s in the `Dockerfile` and the version in `README.md`. Dependabot does not track it.
- Keep the image non-root with UID `10001`, and keep `HEALTHCHECK` and the OCI labels.
- When ports, env vars or paths change, update `README.md`, this file and `llms.txt` in the same pull request.
- The workflow must pass `actionlint` (`docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest`), the scripts `shellcheck`.
- `README.md` is also the Docker Hub description, so keep it under 25,000 characters.
