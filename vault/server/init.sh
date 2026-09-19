#!/bin/sh
# Auto-init + auto-unseal loop for the single Vault node.
#
# One key share, threshold 1: the key sits on the same disk as the data, so
# splitting it would add ceremony and no protection. The key and the initial
# root token are written to /vault/init (a volume on the server), mode 600.
# bootstrap.sh consumes and deletes the root token.
set -u

KEY_FILE=/vault/init/unseal.key
TOKEN_FILE=/vault/init/root.token

log() { echo "vault-init: $*"; }

while true; do
  STATUS="$(vault status 2>/dev/null)"
  RC=$?
  # rc 0 = unsealed, 2 = sealed or uninitialized, 1 = unreachable
  if [ "$RC" -eq 2 ]; then
    INITIALIZED="$(printf '%s\n' "$STATUS" | awk '$1=="Initialized"{print $2}')"
    if [ "$INITIALIZED" != "true" ]; then
      if [ -s "$KEY_FILE" ]; then
        log "vault reports uninitialized but $KEY_FILE exists; refusing to re-initialize"
        sleep 30
        continue
      fi
      # Initialize only if the key can be persisted: a key that is generated but
      # not saved leaves Vault sealed forever.
      umask 077
      if ! ( : > "$KEY_FILE" && : > "$TOKEN_FILE" ) 2>/dev/null; then
        log "ERROR: cannot write to /vault/init; not initializing"
        sleep 30
        continue
      fi
      if OUT="$(vault operator init -key-shares=1 -key-threshold=1)"; then
        printf '%s\n' "$OUT" | awk '/^Unseal Key 1:/{print $4}' > "$KEY_FILE"
        printf '%s\n' "$OUT" | awk '/^Initial Root Token:/{print $4}' > "$TOKEN_FILE"
        log "initialized"
      else
        sleep 5
        continue
      fi
    fi
    if [ -s "$KEY_FILE" ]; then
      vault operator unseal "$(cat "$KEY_FILE")" >/dev/null && log "unsealed"
    fi
  fi
  sleep 5
done
