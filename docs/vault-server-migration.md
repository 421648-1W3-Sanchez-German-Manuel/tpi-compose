# Vault: migration to the real platform server

What actually happened when Vault moved from a developer's PC to the shared platform
server (`sv-tpi`, user `sorias`), and what it verified. The plan this followed is
`docs/vault-handoff.md` (the "Left to do" list) and the original design docs
(`vault-contract.md`, `vault-server.md`, `vault-teams.md`).

## Result

Vault runs on the real server as its own node (`tpi-vault`, `tag:vault`) on the real
tailnet, next to `tpi-plataforma`. The real platform stack (`tpi-deploy`, `main`) reads
its Identity secrets from it. Verified against the real deployment, not a local stand-in.

## What was done, in order

1. **Backup, before touching anything**: `~/env-antes-de-vault.bak` (old `tpi-deploy`
   `.env`) and `~/users-antes-de-vault.sql` (`mysqldump` of the `users` database), both
   left in `sorias`'s home directory as the rollback path.
2. **`tpi-compose` cloned on the server**, `main` (post-merge).
3. **TLS**: `vault/tls/gen-certs.sh tpi-vault.tail767776.ts.net` — the cert's SAN needs the
   tailnet's real MagicDNS name, not just `vault`/`localhost`/`host.docker.internal`
   (those cover local testing only).
4. **`vault/server/.env`**: the tagged (`tag:vault`) Tailscale auth key goes here. Nothing
   else in the template needed changing.
5. **`docker compose -f vault/server/docker-compose.yml -f vault/server/docker-compose.tailscale.yml
   up -d`**: the `tpi-vault` node came up on the tailnet, `initialized` and `unsealed` by
   `vault-init` on its own (auto-unseal, single key share in the `vault-init-data` volume).
6. **Bootstrap** (`bootstrap.sh`, one time): policies, the four `identity-*` AppRoles, root
   token revoked. Only **one** operator account was created at this point (no interactive
   session to collect a real list of operators and their passwords) — see the open item in
   `vault-handoff.md`.
7. **`identity/db` seeded by hand, not by the script**: the server's MySQL volume already had
   real data, so its current root password had to become Vault's `identity/db` secret
   *before* running `vault-seed-identity.sh` (which never overwrites an existing secret).
   Done by piping the password straight from the old `.env` file into `vault kv put`,
   without it ever going through a shell history or a terminal that echoes it.
8. **`vault-seed-identity.sh`**: created `identity/bootstrap`, `identity/grafana`,
   `identity/jwt` (all three didn't exist yet); kept `identity/db` (the one just seeded).
   **`identity/jwt` is a freshly generated key pair** — the server's previous JWT keys were
   not migrated in. That invalidates whatever sessions were open against the old platform;
   it does not touch any account or password. If the previous keys need to be kept in a
   future migration, they have to be loaded into `identity/jwt` *before* this step runs.
9. **`vault-agent-creds.sh all`**: issued AppRole credentials for the three Identity Agents
   used by `tpi-deploy` (`identity-users`, `identity-mysql`, `identity-dev-mailbox`).
10. **`tpi-deploy` updated to `main`** on the server (fast-forward, no conflicts), Agent
    credentials and `vault/ca.pem` copied over from `tpi-compose`'s output, `.env` updated
    (`TPI_TAG` to the new image tag, `VAULT_ADDR=https://tpi-vault:8200`, the two password
    variables removed).
11. **`docker compose pull && docker compose up -d`**: recreated `mysql`, `dev-mailbox`,
    `users-service` and added the three Vault Agent sidecars; everything else
    (`nginx`, `webapp`, `api-gateway`, `echo-service`, `eureka`, `kafka`, `redis`,
    `tailscale`) kept running the whole time — no downtime for the other teams.

## Verified against the real server (not a local stand-in)

- The three Vault Agents (`vault-agent-users`, `vault-agent-mysql`, `vault-agent-dev-mailbox`)
  healthy.
- `users-service`: zero `DB_PASSWORD`/`ADMIN_BOOTSTRAP_PASSWORD` in its environment.
- `mysql`: root password from `/run/secrets/db-password`, matching the preserved password.
- `vault-agent-users` authenticates and reports `vault status` against the real
  `https://tpi-vault:8200`.
- `/.well-known/jwks.json` (through `api-gateway`) serves the new key (`kid=dev`).
- Eureka lists `API-GATEWAY`, `USERS-SERVICE`, `ECHO-SERVICE` — the rest of the platform's
  registrations were untouched by the change.
- `dev-mailbox` `/healthz` OK.
- `/api/users/public/auth/login` returns `401` on a wrong password — the full chain
  (gateway → users-service → MySQL) is live. The pre-existing admin account survived the
  migration with its original password (the MySQL volume was never recreated); only a
  session that predates the new JWT key would need to log in again.

## Not exercised yet

- Real team onboarding (`vault-onboard-team.sh`) against this server — no team has asked
  for one yet.
- The Tailscale ACL denial paths (`tag:microservicio` should reach `tag:vault:8200` but not
  `:22`/`:8201`) were not re-tested live in this migration; they were validated earlier
  against test nodes (see the ACL note in `vault-contract.md`) and the ACL itself has not
  changed since.
- Vault backup and unseal-key rotation: still out of scope, unchanged from the original
  decision in `vault-handoff.md`.
