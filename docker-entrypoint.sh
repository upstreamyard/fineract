#!/bin/sh
# Entrypoint of the upstreamyard Apache Fineract image.
#  1. Reads FINERACT_*_FILE variables (e.g. FINERACT_HIKARI_PASSWORD_FILE) into FINERACT_*.
#  2. HTTPS (Fineract's default): without your own keystore, generates a self-signed
#     certificate for this container instead of using the key that ships inside Fineract
#     (its private key is public). HTTP on 8080 when FINERACT_SERVER_SSL_ENABLED=false.
#  3. Starts Fineract with our Java options; jars in /app/lib and /app/plugins are loaded.
#  4. On write instances, replaces the default password of user "mifos" with
#     FINERACT_ADMIN_PASSWORD once Fineract is ready (only while it is still "password").
set -eu

log() { echo "upstreamyard-entrypoint: $*" >&2; }

# Any other command (e.g. "bash") runs instead of Fineract.
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  exec "$@"
fi

# --- 1. FINERACT_*_FILE -> FINERACT_* -------------------------------------------------
for file_var in $(env | sed -n 's/^\(FINERACT_[A-Z0-9_]*\)_FILE=.*/\1/p'); do
  file=""
  eval "file=\${${file_var}_FILE}"
  eval "already=\${${file_var}:-}"
  [ -z "$already" ] || { log "both $file_var and ${file_var}_FILE are set; using $file_var"; continue; }
  [ -r "$file" ] || { log "${file_var}_FILE: cannot read $file"; exit 1; }
  value=$(cat "$file")
  export "$file_var=$value"
  unset "${file_var}_FILE"
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
profiles=",$(lower "${SPRING_PROFILES_ACTIVE:-}" | tr -d ' '),"
liquibase_only=false
case "$profiles" in *,liquibase-only,*) liquibase_only=true ;; esac

# --- 2. HTTPS / HTTP ---------------------------------------------------------------------
if [ "$(lower "${FINERACT_SERVER_SSL_ENABLED:-true}")" = false ]; then
  export FINERACT_SERVER_PORT="${FINERACT_SERVER_PORT:-8080}"
  scheme=http
else
  export FINERACT_SERVER_PORT="${FINERACT_SERVER_PORT:-8443}"
  scheme=https
  if [ -z "${FINERACT_SERVER_SSL_KEY_STORE:-}" ] && [ "$liquibase_only" = false ]; then
    tls_dir=$(mktemp -d /tmp/fineract-tls.XXXXXX)
    store_pw=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    host=$(hostname)
    keytool -genkeypair -alias fineract -keyalg EC -groupname secp256r1 -sigalg SHA256withECDSA \
      -validity 3650 -dname "CN=$host" -ext "SAN=dns:$host,dns:localhost,ip:127.0.0.1" \
      -storetype PKCS12 -keystore "$tls_dir/keystore.p12" -storepass "$store_pw" -keypass "$store_pw" \
      >/dev/null 2>&1 || { log "could not create a TLS certificate"; exit 1; }
    export FINERACT_SERVER_SSL_KEY_STORE="$tls_dir/keystore.p12"
    export FINERACT_SERVER_SSL_KEY_STORE_PASSWORD="$store_pw"
    log "HTTPS on port $FINERACT_SERVER_PORT with a self-signed certificate for $host (generated at start; mount your own keystore for production, or terminate TLS in front of Fineract)"
  fi
fi

# --- 4. Default password of user "mifos" (runs in the background) --------------------
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

replace_default_password() {
  base="$scheme://127.0.0.1:$FINERACT_SERVER_PORT${FINERACT_SERVER_SERVLET_CONTEXT_PATH:-/fineract-provider}"
  tenant="${FINERACT_DEFAULT_TENANTDB_IDENTIFIER:-default}"
  waited=0
  until curl -fsk -o /dev/null --max-time 5 "$base/actuator/health/readiness"; do
    sleep 5
    waited=$((waited + 5))
    [ "$waited" -lt "${FINERACT_ADMIN_PASSWORD_TIMEOUT:-3600}" ] || { log "Fineract not ready after ${waited}s; default password of user mifos not checked"; return 0; }
  done
  response=$(curl -sk --max-time 60 -H "Fineract-Platform-TenantId: $tenant" -H 'Content-Type: application/json' \
    -d '{"username":"mifos","password":"password"}' "$base/api/v1/authentication" || true)
  user_id=$(printf '%s' "$response" | sed -n 's/.*"userId":\([0-9][0-9]*\).*/\1/p')
  if [ -z "$user_id" ]; then
    log "user mifos does not use the default password (tenant $tenant)"
    return 0
  fi
  if [ -z "${FINERACT_ADMIN_PASSWORD:-}" ]; then
    log "WARNING: user mifos of tenant $tenant still has the default password \"password\". Set FINERACT_ADMIN_PASSWORD, or change it now."
    return 0
  fi
  pw=$(json_escape "$FINERACT_ADMIN_PASSWORD")
  status=$(curl -sk --max-time 60 -o /tmp/fineract-admin-password.out -w '%{http_code}' -u 'mifos:password' \
    -H "Fineract-Platform-TenantId: $tenant" -H 'Content-Type: application/json' -X PUT \
    -d "{\"password\":\"$pw\",\"repeatPassword\":\"$pw\"}" "$base/api/v1/users/$user_id" || true)
  if [ "$status" = 200 ]; then
    log "replaced the default password of user mifos (tenant $tenant) with FINERACT_ADMIN_PASSWORD"
  else
    log "could not set FINERACT_ADMIN_PASSWORD for user mifos (HTTP $status): $(head -c 500 /tmp/fineract-admin-password.out 2>/dev/null)"
  fi
  rm -f /tmp/fineract-admin-password.out
}

if [ "$liquibase_only" = false ] \
  && [ "$(lower "${FINERACT_MODE_WRITE_ENABLED:-true}")" != false ] \
  && [ "$(lower "${FINERACT_SECURITY_BASICAUTH_ENABLED:-true}")" != false ]; then
  # Double fork: the checker is re-parented to tini, which reaps it.
  ( replace_default_password & )
fi

# --- 3. Start Fineract -------------------------------------------------------------------
# PropertiesLauncher adds every jar in loader.path to the classpath: /app/lib holds the
# MariaDB driver, /app/plugins is for your own jars (drivers, Fineract plugins).
# shellcheck disable=SC2086
exec java ${JAVA_OPTS_MEMORY:--XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=60.0} \
  -Duser.timezone=UTC -Dfile.encoding=UTF-8 -Duser.home=/var/lib/fineract -Djava.io.tmpdir=/tmp \
  -Dloader.path=/app/lib,/app/plugins \
  ${JAVA_OPTS:-} \
  -jar /app/fineract-provider.jar "$@"
