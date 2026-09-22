# Vault on the shared server (Tailscale)

Vault runs as its own compose project (`tpi-vault`) next to the platform stack
(`tpi-deploy`). It joins the tailnet through its own sidecar with `tag:vault`;
micros and Agents reach it as `https://tpi-vault:8200` (MagicDNS).

## Tailnet prerequisites

- `tagOwners`: `"tag:vault": ["autogroup:admin"]`.
- Grants `tag:microservicio -> tag:vault` and `tag:plataforma -> tag:vault`,
  both `tcp:8200`. No grant out of `tag:vault`, none between micros.
- An auth key created with `tag:vault` (not reusable, not ephemeral).

## Install (once, on the server)

```bash
git clone <tpi-compose> && cd tpi-compose && git checkout feature/vault
./vault/tls/gen-certs.sh tpi-vault.<tailnet>.ts.net
cp vault/server/tailscale.env.example vault/server/.env   # set TS_AUTHKEY
F="-f vault/server/docker-compose.yml -f vault/server/docker-compose.tailscale.yml"
docker compose $F up -d
BOOTSTRAP_OPERATORS="alice bob" docker compose $F exec -it -e BOOTSTRAP_OPERATORS vault-init sh /init/bootstrap.sh
```

Operator commands (team onboarding, seeding) run from the server through the
sidecar namespace, nothing is published on the host:

```bash
export VAULT_DOCKER_NETWORK=container:tpi-vault-ts VAULT_ADDR=https://localhost:8200
./scripts/vault-seed-identity.sh
./scripts/vault-onboard-team.sh <team> [member ...]
./scripts/vault-agent-creds.sh identity-users
```

`secrets/vault/tls/ca.pem` is public: it is what every consumer needs to trust
Vault. Distribute that file, never `ca-key.pem`.

## Verify

```bash
docker compose $F ps                                  # tailscale, vault: healthy
docker exec tpi-vault-ts tailscale status | head -3   # node online, tag:vault
```

From any mesh container (a micro or the platform node):
`wget -qO- --ca-certificate=ca.pem https://tpi-vault:8200/v1/sys/health`.

## Notes

- `vault` and `vault-init` share the sidecar's network namespace, so nothing is
  published on the host. `vault-init` talks to `https://localhost:8200`.
- The Tailscale state lives in the `tailscale-state` volume: do not `down -v`
  or the node re-registers and the auth key is spent.
- Verified on the real tailnet (2026-09-21): node joined as tag:vault; a dummy micro
  (tag:microservicio) and a stand-in platform node (tag:plataforma) reached
  `tpi-vault:8200`; `:22`, `:8201` and the platform `:80` from a micro were
  blocked; a team unwrapped its secret_id, wrote launch parameters, and the
  app started with them; rotation reaches the file within the render interval
  (1 min); Vault restarts auto-unseal.
