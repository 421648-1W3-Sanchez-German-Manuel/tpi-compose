# Vault: handoff

State of the Vault work, what was decided and why, what is left. The contract
itself (paths, files, policies) is in [vault-contract.md](vault-contract.md); this
is the story around it.

- PR here: `feature/vault` (draft). Companion PR in `users`: `feature/vault-secrets`
  (draft, backward compatible, can merge first).
- Verified end to end against a local Vault. **Not** verified: Tailscale and the
  real server.

## What exists

| Where | What |
|---|---|
| `vault/server/` | The shared Vault: compose, `vault.hcl`, `init.sh` (auto-init and auto-unseal), `bootstrap.sh` (one time). |
| `vault/policies/` | `operator`, `identity-users`, `identity-mysql`, `identity-dev-mailbox`, `identity-grafana`. |
| `vault/agent/` | One Vault Agent config per consumer. |
| `vault/tls/gen-certs.sh` | Private CA and server certificate. |
| `docker-compose.yml` | Four `vault-agent-*` sidecars, tmpfs volumes, one network per Agent; mysql, users-service, dev-mailbox and grafana read files instead of environment variables. |
| `scripts/` | `vault-seed-identity.sh`, `vault-agent-creds.sh`, `seed-service-client-v2.sh`, `lib/vault.sh`; `resolver-padron.sh` and `seed-echo-client.sh` adapted. |
| `dev-mailbox/server.js` | Reads `DB_PASSWORD_FILE` when set. |

Removed: `docker-compose.normal.yml` (duplicated the main compose; added by
Ibazeta on 2026-09-17, so tell them) and `scripts/seed-service-client.sh`
(replaced by the v2).

## Decisions and why

- **One Vault, one owner, deployed apart from the stack.** Policies only mean
  something when the client cannot administer the server; and development happens
  without `tpi-compose` running, so Vault cannot live inside it.
- **Agent sidecar + files, no SDK.** Consumers read a file; `FileSystemSigningKeyProvider`
  (DEC-18) is untouched.
- **Automatic unseal, 1 key share.** The key sits next to the data on the server;
  splitting it would add ceremony and no protection. Anyone owning the host owns both.
  The root token is used once and revoked.
- **Namespace `secret/tpi/identity/*`** (the subsystem, not `users`). `shared/clients/<team>`
  and `<team>/*` belong to other teams (onboarded with `vault-onboard-team.sh`); operators cannot read `<team>/*`.
- **Each Agent alone on its own network.** It needs a way out to Vault and nothing
  needs a way in; consumer and Agent only share a tmpfs volume. (The Vault spec
  artifact said "shared with its consumer"; this is stricter and equivalent.)
- **Grafana is in Vault** (it had a hardcoded `admin`); **end users' passwords are
  not** (BCrypt hashes in MySQL, Vault adds nothing there).
- **The client secret goes to Vault, its hash stays in MySQL** (`seed-service-client-v2.sh`).

## Things that bit us (worth knowing)

- Spring gives **environment variables precedence over Config Tree**. If
  `DB_PASSWORD` or `ADMIN_BOOTSTRAP_PASSWORD` is set anywhere, the Vault file is
  silently ignored. The compose no longer sets them.
- `vault-init` must run as root, and must check it can write the key **before**
  initializing: a key generated but not saved leaves Vault sealed forever.
- The Vault image entrypoint already passes `-config=/vault/config`; passing the
  file again loads the listener twice ("address already in use").
- The image has no `jq`, `openssl` or `curl`; `init.sh` parses with `awk`.
- Agent templates use `{{ with secret "..." }}`. The `(secret "...").Data...` form fails
  on the Agent's first pass.
- Files are rendered `0444`: the Agent (uid 100) and `users` (`app`, also uid 100)
  only matched by coincidence with `0400`.
- A tmpfs volume exists while a container has it mounted; when the last one stops it
  is gone, which is fine because the Agent re-renders on start and `depends_on` waits for it.
- On Windows, a stray `OPENSSL_CONF` (PostgreSQL ODBC leaves one) breaks `openssl`;
  the scripts unset it when it points nowhere. Git Bash rewrites `/paths` passed to
  native tools: use `MSYS_NO_PATHCONV=1` when testing by hand.
- By default the Vault listener asks every client for a TLS certificate, and browsers then show a
  "select a certificate" dialog before the UI. `tls_disable_client_certs = true` turns it off (we
  authenticate with AppRole and userpass, never certificates).
- Pinned to `hashicorp/vault:2.1.1`.

## Existing local setups

- **A MySQL volume created before this change keeps the old root password**; MySQL
  ignores `MYSQL_ROOT_PASSWORD_FILE` once it is initialized. Either `docker compose
  down -v` (loses the dev data) or, before seeding, store the current password in
  Vault: `vault kv put -mount=secret tpi/identity/db password=<current>`
  (`vault-seed-identity.sh` keeps what already exists).
- Add `VAULT_ADDR` to your `.env`. `MYSQL_ROOT_PASSWORD` and `ADMIN_BOOTSTRAP_PASSWORD`
  there are no longer read. `secrets/jwt-private.pem` and `secrets/jwks/` are unused now.

## Try it locally

```bash
./vault/tls/gen-certs.sh
docker compose -f vault/server/docker-compose.yml up -d
BOOTSTRAP_OPERATORS="alice" OPERATOR_PASSWORD_alice='<choose one>' docker compose \
  -f vault/server/docker-compose.yml exec -T -e BOOTSTRAP_OPERATORS -e OPERATOR_PASSWORD_alice \
  vault-init sh /init/bootstrap.sh

export VAULT_ADDR=https://localhost:8200 VAULT_USER=alice     # asks for the password
./scripts/vault-seed-identity.sh
./scripts/vault-agent-creds.sh all

VAULT_ADDR=https://host.docker.internal:8200 docker compose up -d --build
```

## Left to do

1. **Deploy on the server and test through Tailscale.** `gen-certs.sh <tailscale-host-or-ip>`,
   `VAULT_BIND_ADDR` set to that address (a Vault bound to `127.0.0.1` is reachable from
   containers on Docker Desktop only), check that a container reaches the `100.x` address,
   and whether `tailscale cert` can replace the private CA.
2. **The Tailscale part of onboarding**: a tagged auth key per team, created in the Tailscale console.
   Everything else of the team onboarding is done (see below).
3. Backup and restore of Vault (deferred on purpose).
4. Rotating the JWT kid (file name and `JWT_ACTIVE_KID` change together).
5. Tailscale's free plan has 50 tagged resources: microservices, the Vault node and every
   laptop that joins with a team key all count.
6. Sync the Vault spec artifact with the implementation (AppRole names `identity-<consumer>`,
   Agent alone on its network).

## Team onboarding (added after the first version of this PR)

- `scripts/vault-onboard-team.sh <team> [member ...]`: policy `team-<team>`, AppRole `<team>`, wrapped
  `secret_id`, one userpass account per member, and the team's Agent config. Verified end to end: the
  wrapping token works once; the team reads and writes only `secret/tpi/<team>/*` (403 on identity, on
  another team and on creating policies); an identity operator gets 403 on the team's path; the Agent
  renders `app.env`; the loader keeps `$$`, spaces and quotes literal.
- **Launch parameters and env vars** go in `secret/tpi/<team>/env`, rendered as `/run/secrets/app.env`
  and loaded with `vault/agent/load-env.sh`. Restart the service to pick up a change.
- `scripts/vault-apply-policies.sh` reloads `vault/policies/*.hcl` into a running Vault.
- **The UI is on** (`ui = true`): `<VAULT_ADDR>/ui`, method Username. Browsers warn about the private CA.
- Guide for teams: [vault-teams.md](vault-teams.md). The compose example in it was run as written.
- Not covered by a test: the UI itself (checked that it is served and that the API calls it needs are
  allowed), and reaching Vault through Tailscale.
