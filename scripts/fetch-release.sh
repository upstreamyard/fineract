#!/usr/bin/env bash
# Downloads the official Apache Fineract binary release, checks its SHA-512 and its GPG
# signature against the Fineract KEYS file, and unpacks it into ./upstream.
# Prints the Java version the release was compiled for (from its class files), which CI
# passes to the Docker build as JAVA_VERSION.
# Usage: scripts/fetch-release.sh <version>   (e.g. 1.16.1)
set -euo pipefail

VERSION=${1:?usage: $0 <version>}
FILE="apache-fineract-bin-${VERSION}.tar.gz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# The current release lives on downloads.apache.org, older ones only on archive.apache.org.
for base in https://downloads.apache.org/fineract https://archive.apache.org/dist/fineract; do
  if curl -fsSLO "$base/$VERSION/$FILE"; then
    curl -fsSLO "$base/$VERSION/$FILE.sha512"
    curl -fsSLO "$base/$VERSION/$FILE.asc"
    break
  fi
done
[ -f "$FILE" ] || { echo "Release $VERSION not found" >&2; exit 1; }
curl -fsSL -o KEYS https://downloads.apache.org/fineract/KEYS

# The .sha512 file is in "gpg --print-md" format (upper case, split into groups).
expected=$(sed 's/^[^:]*://' "$FILE.sha512" | tr -d ' \n' | tr 'A-F' 'a-f')
actual=$(sha512sum "$FILE" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "SHA-512 mismatch for $FILE" >&2; exit 1; }
echo "$FILE: SHA-512 OK"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import KEYS 2>/dev/null
gpg --batch --verify "$FILE.asc" "$FILE"

rm -rf "$ROOT/upstream"
mkdir -p "$ROOT/upstream"
# Only what the image needs: the executable server jar and the licence files.
tar xzf "$FILE" -C "$ROOT/upstream" --strip-components=1 \
  "apache-fineract-bin-${VERSION}/fineract-provider-${VERSION}.jar" \
  "apache-fineract-bin-${VERSION}/LICENSE" "apache-fineract-bin-${VERSION}/NOTICE" \
  "apache-fineract-bin-${VERSION}/licenses"
mv "$ROOT/upstream/fineract-provider-${VERSION}.jar" "$ROOT/upstream/fineract-provider.jar"

# Class file major version 69 = Java 25, 65 = Java 21, 61 = Java 17.
major=$(unzip -p "$ROOT/upstream/fineract-provider.jar" BOOT-INF/classes/org/apache/fineract/ServerApplication.class \
  | od -An -tu1 -j7 -N1 | tr -d ' ')
java=$((major - 44))
echo "$java" > "$ROOT/upstream/JAVA_VERSION"
echo "Fineract $VERSION unpacked into upstream/ (built for Java $java)"
