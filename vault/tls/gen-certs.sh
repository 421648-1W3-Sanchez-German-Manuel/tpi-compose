#!/usr/bin/env bash
# Generates a private CA and the TLS certificate Vault listens with.
#
#   ./vault/tls/gen-certs.sh [extra-san[,extra-san...]]   # DNS names or IPs
#   ./vault/tls/gen-certs.sh --force                      # regenerate
#
# Extra SANs are what clients will use to reach Vault (for example the
# Tailscale hostname or IP of the server). The defaults cover the container
# network (vault), the local host and Docker Desktop (host.docker.internal).
#
# Output goes to secrets/vault/tls (gitignored). ca.pem is public: it is what
# every Vault Agent needs to trust the server. ca-key.pem never leaves here.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash rewrites "/CN=..." into a Windows path otherwise
# Some Windows installers (PostgreSQL ODBC, for one) leave OPENSSL_CONF pointing at a file that does not exist.
if [ -n "${OPENSSL_CONF:-}" ] && [ ! -f "$OPENSSL_CONF" ]; then unset OPENSSL_CONF; fi

cd "$(dirname "$0")/../.."
OUT=secrets/vault/tls

FORCE=0
EXTRA="${VAULT_TLS_EXTRA_SANS:-}"
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) EXTRA="$a" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "openssl is not on your PATH (Git for Windows ships it in usr/bin)." >&2; exit 1; }

if [ -f "$OUT/server.pem" ] && [ "$FORCE" -eq 0 ]; then
  echo "$OUT/server.pem already exists; use --force to regenerate." >&2
  exit 0
fi

mkdir -p "$OUT"
SAN="DNS:vault,DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1"
IFS=',' read -r -a EXTRAS <<< "$EXTRA"
for e in "${EXTRAS[@]:-}"; do
  [ -z "$e" ] && continue
  if [[ "$e" =~ ^[0-9.]+$ ]]; then SAN="$SAN,IP:$e"; else SAN="$SAN,DNS:$e"; fi
done

openssl genrsa -out "$OUT/ca-key.pem" 4096 2>/dev/null
openssl req -x509 -new -key "$OUT/ca-key.pem" -sha256 -days 3650 -subj "/CN=tpi-vault-ca" -out "$OUT/ca.pem"

openssl genrsa -out "$OUT/server-key.pem" 2048 2>/dev/null
openssl req -new -key "$OUT/server-key.pem" -subj "/CN=vault" -out "$OUT/server.csr"
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$SAN" > "$OUT/server.ext"
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca-key.pem" -CAcreateserial \
  -sha256 -days 825 -extfile "$OUT/server.ext" -out "$OUT/server.pem" 2>/dev/null
rm -f "$OUT/server.csr" "$OUT/server.ext" "$OUT/ca.srl"

# The container runs Vault as uid 100 and must read the key through the bind mount.
chmod 0755 "$OUT"
chmod 0644 "$OUT/server-key.pem" "$OUT/server.pem" "$OUT/ca.pem"
chmod 0600 "$OUT/ca-key.pem"

echo "Generated $OUT"
openssl x509 -in "$OUT/server.pem" -noout -enddate -ext subjectAltName
