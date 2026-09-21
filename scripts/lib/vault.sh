# Shared helpers for the scripts that talk to Vault. Source it, do not run it.
#
# Needs VAULT_ADDR (the shared Vault). Uses the local `vault` binary when there
# is one and falls back to the official image otherwise, so nothing has to be
# installed on the operator's machine besides Docker.
#
# shellcheck shell=bash

# Some Windows installers leave OPENSSL_CONF pointing at a file that does not exist.
if [ -n "${OPENSSL_CONF:-}" ] && [ ! -f "$OPENSSL_CONF" ]; then unset OPENSSL_CONF; fi

: "${VAULT_ADDR:?set VAULT_ADDR to the shared Vault address (see .env.example)}"
VAULT_CACERT="${VAULT_CACERT:-secrets/vault/tls/ca.pem}"
VAULT_IMAGE="${VAULT_IMAGE:-hashicorp/vault:2.1.1}"
[ -f "$VAULT_CACERT" ] || { echo "CA certificate not found at $VAULT_CACERT (set VAULT_CACERT)" >&2; exit 1; }
export VAULT_ADDR VAULT_CACERT

vault_cli() {
  if command -v vault >/dev/null 2>&1; then
    vault "$@"
    return
  fi
  local ca_dir ca
  ca_dir="$(cd "$(dirname "$VAULT_CACERT")" && (pwd -W 2>/dev/null || pwd))"
  ca="$ca_dir/$(basename "$VAULT_CACERT")"
  # VAULT_DOCKER_NETWORK=container:<sidecar> runs the CLI inside the namespace
  # of a container that is on the tailnet (the Vault sidecar on the server, or
  # any mesh sidecar); VAULT_ADDR is then used as given.
  if [ -n "${VAULT_DOCKER_NETWORK:-}" ]; then
    MSYS_NO_PATHCONV=1 docker run --rm -i --network "$VAULT_DOCKER_NETWORK" \
      -e VAULT_ADDR -e VAULT_TOKEN -e VAULT_CACERT=/vault-ca.pem \
      -v "$ca:/vault-ca.pem:ro" "$VAULT_IMAGE" vault "$@"
    return
  fi
  # From inside a container, the host's loopback is host.docker.internal.
  local addr="${VAULT_ADDR/\/\/localhost/\/\/host.docker.internal}"
  addr="${addr/\/\/127.0.0.1/\/\/host.docker.internal}"
  MSYS_NO_PATHCONV=1 docker run --rm -i --add-host host.docker.internal:host-gateway \
    -e VAULT_ADDR="$addr" -e VAULT_TOKEN -e VAULT_CACERT=/vault-ca.pem \
    -v "$ca:/vault-ca.pem:ro" "$VAULT_IMAGE" vault "$@"
}

# Ensures VAULT_TOKEN is set: VAULT_TOKEN itself, or a userpass login using
# VAULT_USER / VAULT_PASSWORD (prompted when missing). The token is never
# written to disk.
vault_login() {
  [ -n "${VAULT_TOKEN:-}" ] && return 0
  local user="${VAULT_USER:-}" pw="${VAULT_PASSWORD:-}"
  [ -n "$user" ] || read -r -p "Vault username: " user
  [ -n "$pw" ] || { read -r -s -p "Vault password: " pw; echo; }
  VAULT_TOKEN="$(vault_cli login -no-store -token-only -method=userpass username="$user" password="$pw" </dev/null)" \
    || { echo "Vault login failed" >&2; exit 1; }
  export VAULT_TOKEN
}
