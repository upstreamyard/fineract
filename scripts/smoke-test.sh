#!/usr/bin/env bash
# Smoke test for the Fineract image, run by CI before anything is published.
#  1. PostgreSQL, first start: migrations, FINERACT_ADMIN_PASSWORD replaces mifos/password,
#     generated TLS certificate, client + document upload into /var/lib/fineract,
#     Prometheus metrics, clean stop, restart with the document still there.
#  2. Kubernetes style: a liquibase-only run, then a server with migrations off, HTTP on
#     8080, *_FILE secrets and a read-only root filesystem.
#  3. Instance types on the database of step 1: a read instance and a batch instance.
#  4. MariaDB with the bundled driver.
#  5. A changed tenant master password is refused.
# Usage: scripts/smoke-test.sh <image>   (cleans up its containers, volumes and network;
#        set KEEP=1 to keep them for inspection)
set -euo pipefail

IMAGE=${1:?usage: $0 <image>}
NET=fineract-smoke
PREFIX=smoke-fin
ADMIN_PW='Tr0ub4dor"&\x9Kq'   # meets Fineract's "strong" policy; quote and backslash test escaping
MASTER_PW='m4ster-Secret'
DB_PW='db-Secret-1'
TENANT='Fineract-Platform-TenantId: default'
WORK=$(mktemp -d)
chmod 755 "$WORK"

containers() { docker ps -aq --filter "name=^${PREFIX}-"; }
cleanup() {
  [ "${KEEP:-}" = 1 ] && return
  # shellcheck disable=SC2046
  docker rm -f $(containers) >/dev/null 2>&1 || true
  docker volume rm "$PREFIX-data" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  for c in $(docker ps -a --filter "name=^${PREFIX}-" --format '{{.Names}}'); do
    echo "--- $c"; docker logs "$c" 2>&1 | tail -25 || true
  done
  exit 1
}
# The log is read in full first: "docker logs | grep -q" fails at random under pipefail.
log_has() { local out; out=$(docker logs "$1" 2>&1); grep -q -- "$2" <<< "$out"; }
wait_healthy() { # container [seconds]
  local limit=${2:-480} waited=0
  while [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" != healthy ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || fail "$1 exited"
    [ "$waited" -lt "$limit" ] || fail "$1 not healthy after ${limit}s"
    sleep 5; waited=$((waited + 5))
  done
  echo "$1 healthy after ${waited}s"
}
# api CONTAINER METHOD PATH [USER:PASSWORD] [JSON]: prints the HTTP status. Runs curl inside
# the container (HTTPS on 8443 unless the container has FINERACT_SERVER_SSL_ENABLED=false).
api() {
  local c=$1 method=$2 path=$3 cred=${4:-} body=${5:-} url
  url=$(docker exec "$c" sh -c 'if [ "$FINERACT_SERVER_SSL_ENABLED" = false ]; then echo http://127.0.0.1:8080; else echo https://127.0.0.1:8443; fi')
  docker exec "$c" curl -sk -o /dev/null -w '%{http_code}' -X "$method" ${cred:+-u "$cred"} -H "$TENANT" \
    ${body:+-H 'Content-Type: application/json' -d "$body"} "$url/fineract-provider$path"
}
wait_log() { # container pattern [seconds]
  local waited=0
  until log_has "$1" "$2"; do
    [ "$waited" -lt "${3:-60}" ] || fail "$1: no log line matching '$2'"
    sleep 2; waited=$((waited + 2))
  done
}

docker network create "$NET" >/dev/null
cat > "$WORK/pg-init.sql" <<EOF
CREATE USER fineract WITH PASSWORD '$DB_PW';
CREATE DATABASE fineract_tenants OWNER fineract;
CREATE DATABASE fineract_default OWNER fineract;
CREATE DATABASE k8s_tenants OWNER fineract;
CREATE DATABASE k8s_default OWNER fineract;
EOF
cat > "$WORK/mariadb-init.sql" <<EOF
CREATE DATABASE fineract_tenants;
CREATE DATABASE fineract_default;
CREATE USER 'fineract'@'%' IDENTIFIED BY '$DB_PW';
GRANT ALL ON fineract_tenants.* TO 'fineract'@'%';
GRANT ALL ON fineract_default.* TO 'fineract'@'%';
EOF
printf '%s' "$DB_PW" > "$WORK/db-password"
chmod 644 "$WORK"/*
printf '%%PDF-1.4\n%% smoke test\n' > "$WORK/contract.pdf"

docker run -d --name "$PREFIX-pg" --network "$NET" -e POSTGRES_PASSWORD=root-pw \
  -v "$WORK/pg-init.sql:/docker-entrypoint-initdb.d/01.sql:ro" postgres:18 >/dev/null
docker run -d --name "$PREFIX-mariadb" --network "$NET" -e MARIADB_ROOT_PASSWORD=root-pw \
  -v "$WORK/mariadb-init.sql:/docker-entrypoint-initdb.d/01.sql:ro" mariadb:11.8 \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-snapshot-isolation=OFF >/dev/null
for _ in $(seq 1 60); do docker exec "$PREFIX-pg" pg_isready -q -U postgres -d k8s_default 2>/dev/null && break; sleep 2; done

pg_env=(-e "FINERACT_HIKARI_JDBC_URL=jdbc:postgresql://$PREFIX-pg:5432/fineract_tenants"
  -e FINERACT_HIKARI_USERNAME=fineract -e FINERACT_HIKARI_PASSWORD="$DB_PW"
  -e FINERACT_DEFAULT_TENANTDB_HOSTNAME="$PREFIX-pg" -e FINERACT_DEFAULT_TENANTDB_UID=fineract
  -e FINERACT_DEFAULT_TENANTDB_PWD="$DB_PW" -e FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD="$MASTER_PW"
  -e FINERACT_DEFAULT_TENANTDB_TIMEZONE=UTC)

echo "== 1. PostgreSQL: first start, admin password, documents, metrics, stop and restart"
docker run -d --name "$PREFIX-app" --network "$NET" "${pg_env[@]}" -e FINERACT_ADMIN_PASSWORD="$ADMIN_PW" \
  -v "$PREFIX-data:/var/lib/fineract" "$IMAGE" >/dev/null
wait_healthy "$PREFIX-app"
wait_log "$PREFIX-app" "replaced the default password of user mifos"
[ "$(api "$PREFIX-app" GET /api/v1/offices mifos:password)" = 401 ] || fail "default password still works"
[ "$(api "$PREFIX-app" GET /api/v1/offices "mifos:$ADMIN_PW")" = 200 ] || fail "FINERACT_ADMIN_PASSWORD does not work"
echo "mifos: default password refused, FINERACT_ADMIN_PASSWORD accepted"

host=$(docker exec "$PREFIX-app" hostname)
subject=$(docker exec "$PREFIX-app" sh -c 'curl -vsk -o /dev/null https://127.0.0.1:8443/ 2>&1 | grep "subject:"' || true)
grep -q "CN=$host" <<< "$subject" || fail "certificate is not the generated one: $subject"
echo "TLS: certificate generated for this container ($subject)"

client=$(docker exec "$PREFIX-app" curl -sk -u "mifos:$ADMIN_PW" -H "$TENANT" -H 'Content-Type: application/json' \
  -d '{"officeId":1,"legalFormId":1,"firstname":"Ada","lastname":"Lovelace","active":false,"locale":"en","dateFormat":"dd MMMM yyyy"}' \
  https://127.0.0.1:8443/fineract-provider/api/v1/clients | sed -n 's/.*"clientId":\([0-9]*\).*/\1/p')
[ -n "$client" ] || fail "cannot create a client"
docker cp "$WORK/contract.pdf" "$PREFIX-app:/tmp/contract.pdf"
docker exec "$PREFIX-app" curl -fsk -o /dev/null -u "mifos:$ADMIN_PW" -H "$TENANT" -F name=contract \
  -F "file=@/tmp/contract.pdf;type=application/pdf" "https://127.0.0.1:8443/fineract-provider/api/v1/clients/$client/documents" \
  || fail "document upload failed"
docker exec "$PREFIX-app" sh -c 'find /var/lib/fineract -name contract.pdf | grep -q .' || fail "document not stored in /var/lib/fineract"
echo "Client $client created, document stored in /var/lib/fineract"

metrics=$(docker exec "$PREFIX-app" curl -fsk https://127.0.0.1:8443/fineract-provider/actuator/prometheus)
grep -q '^jvm_memory_used_bytes' <<< "$metrics" || fail "no Prometheus metrics"
echo "Prometheus metrics ok"

start=$(date +%s)
docker stop -t 30 "$PREFIX-app" >/dev/null
took=$(( $(date +%s) - start )); code=$(docker inspect -f '{{.State.ExitCode}}' "$PREFIX-app")
[ "$code" = 143 ] && [ "$took" -lt 20 ] || fail "unclean stop: exit $code after ${took}s"
echo "Clean stop after ${took}s (exit 143)"
docker start "$PREFIX-app" >/dev/null
wait_healthy "$PREFIX-app"
wait_log "$PREFIX-app" "user mifos does not use the default password"
[ "$(api "$PREFIX-app" GET "/api/v1/clients/$client/documents/1/attachment" "mifos:$ADMIN_PW")" = 200 ] || fail "document lost after restart"
echo "Restart: password kept, document still there"

echo "== 2. Kubernetes style: liquibase-only run, then HTTP, *_FILE secrets, read-only root filesystem"
k8s_env=(-e "FINERACT_HIKARI_JDBC_URL=jdbc:postgresql://$PREFIX-pg:5432/k8s_tenants"
  -e FINERACT_HIKARI_USERNAME=fineract -e FINERACT_HIKARI_PASSWORD_FILE=/run/secrets/db-password
  -e FINERACT_DEFAULT_TENANTDB_HOSTNAME="$PREFIX-pg" -e FINERACT_DEFAULT_TENANTDB_NAME=k8s_default
  -e FINERACT_DEFAULT_TENANTDB_UID=fineract -e FINERACT_DEFAULT_TENANTDB_PWD_FILE=/run/secrets/db-password
  -e FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD="$MASTER_PW" -e FINERACT_DEFAULT_TENANTDB_TIMEZONE=UTC
  -v "$WORK/db-password:/run/secrets/db-password:ro")
docker run --name "$PREFIX-migrate" --network "$NET" "${k8s_env[@]}" -e SPRING_PROFILES_ACTIVE=liquibase-only "$IMAGE" >/dev/null 2>&1 \
  || fail "liquibase-only run failed"
log_has "$PREFIX-migrate" "Fineract is running in Liquibase only mode" || fail "liquibase-only profile not active"
echo "liquibase-only run finished with exit 0"
docker run -d --name "$PREFIX-k8s" --network "$NET" "${k8s_env[@]}" -e FINERACT_LIQUIBASE_ENABLED=false \
  -e FINERACT_SERVER_SSL_ENABLED=false -e FINERACT_ADMIN_PASSWORD="$ADMIN_PW" \
  --read-only --tmpfs /tmp:rw,size=256m --tmpfs /var/lib/fineract:rw,uid=10001,gid=10001 "$IMAGE" >/dev/null
wait_healthy "$PREFIX-k8s"
wait_log "$PREFIX-k8s" "replaced the default password of user mifos"
[ "$(api "$PREFIX-k8s" GET /api/v1/offices "mifos:$ADMIN_PW")" = 200 ] || fail "HTTP API does not work"
echo "HTTP on 8080 with *_FILE secrets and a read-only root filesystem ok"

echo "== 3. Instance types (read, batch) and 4. MariaDB"
docker run -d --name "$PREFIX-read" --network "$NET" "${pg_env[@]}" -e FINERACT_LIQUIBASE_ENABLED=false -e FINERACT_NODE_ID=2 \
  -e FINERACT_MODE_WRITE_ENABLED=false -e FINERACT_MODE_BATCH_MANAGER_ENABLED=false -e FINERACT_MODE_BATCH_WORKER_ENABLED=false "$IMAGE" >/dev/null
docker run -d --name "$PREFIX-batch" --network "$NET" "${pg_env[@]}" -e FINERACT_LIQUIBASE_ENABLED=false -e FINERACT_NODE_ID=3 \
  -e FINERACT_MODE_READ_ENABLED=false -e FINERACT_MODE_WRITE_ENABLED=false "$IMAGE" >/dev/null
docker run -d --name "$PREFIX-maria" --network "$NET" \
  -e FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME=org.mariadb.jdbc.Driver \
  -e "FINERACT_HIKARI_JDBC_URL=jdbc:mariadb://$PREFIX-mariadb:3306/fineract_tenants" \
  -e FINERACT_HIKARI_USERNAME=fineract -e FINERACT_HIKARI_PASSWORD="$DB_PW" \
  -e FINERACT_DEFAULT_TENANTDB_HOSTNAME="$PREFIX-mariadb" -e FINERACT_DEFAULT_TENANTDB_PORT=3306 \
  -e FINERACT_DEFAULT_TENANTDB_UID=fineract -e FINERACT_DEFAULT_TENANTDB_PWD="$DB_PW" \
  -e FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD="$MASTER_PW" -e FINERACT_DEFAULT_TENANTDB_TIMEZONE=UTC \
  -e FINERACT_ADMIN_PASSWORD="$ADMIN_PW" "$IMAGE" >/dev/null
wait_healthy "$PREFIX-read"
[ "$(api "$PREFIX-read" GET /api/v1/offices "mifos:$ADMIN_PW")" = 200 ] || fail "read instance does not serve GET"
[ "$(api "$PREFIX-read" POST /api/v1/clients "mifos:$ADMIN_PW" '{"officeId":1}')" = 405 ] || fail "read instance accepts writes"
echo "Read instance: GET 200, POST 405"
wait_healthy "$PREFIX-batch"
[ "$(api "$PREFIX-batch" GET /api/v1/jobs "mifos:$ADMIN_PW")" = 200 ] || fail "batch instance does not serve the jobs API"
[ "$(api "$PREFIX-batch" GET /api/v1/offices "mifos:$ADMIN_PW")" = 405 ] || fail "batch instance serves read APIs"
echo "Batch instance: jobs API 200, read API 405"
wait_healthy "$PREFIX-maria"
wait_log "$PREFIX-maria" "replaced the default password of user mifos"
[ "$(api "$PREFIX-maria" GET /api/v1/offices "mifos:$ADMIN_PW")" = 200 ] || fail "MariaDB: API does not work"
echo "MariaDB 11.8 with the bundled driver ok"

echo "== 5. Changed master password is refused"
docker run -d --name "$PREFIX-badmaster" --network "$NET" "${pg_env[@]}" -e FINERACT_LIQUIBASE_ENABLED=false \
  -e FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD=another-one "$IMAGE" >/dev/null
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' "$PREFIX-badmaster")" = true ] || break; sleep 3; done
[ "$(docker inspect -f '{{.State.Running}}' "$PREFIX-badmaster")" = false ] || fail "server runs with a wrong master password"
log_has "$PREFIX-badmaster" "Invalid master password" || fail "no 'Invalid master password' error"
echo "Wrong master password: server exits with 'Invalid master password'"

echo "All smoke tests passed"
