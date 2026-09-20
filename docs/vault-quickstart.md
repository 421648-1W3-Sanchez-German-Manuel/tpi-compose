# Vault quickstart: try it from scratch, locally

A step-by-step to bring up the shared Vault and the application stack on your own
machine and check that every secret comes from Vault. Every step here was run on a
fresh clone. What each piece is and why: [vault-contract.md](vault-contract.md).

## You need

- Docker Desktop running, with about 8 GB of memory.
- A bash shell: Git Bash on Windows. `openssl` must be on its PATH (Git for Windows ships it).
- Free ports: 3000, 3001, 8200, 8761, 9090. Stop any other stack first.
- No Vault CLI: the scripts use the official image when there is none.

**Where to type the commands.** Every command in this guide goes in a terminal (Git Bash),
opened in the `tpi-compose` folder, unless a step says otherwise. Nothing goes in a file or inside
a container: you type it and run it yourself. Step 1 leaves you in that folder.

## 1. Get the code

The compose builds from sibling folders, so the four repos go side by side:

```bash
mkdir vault-try && cd vault-try
git clone -b feature/vault         <origin>/tpi-compose.git
git clone -b feature/vault-secrets <origin>/users.git
git clone                          <origin>/api-gateway.git
git clone                          <origin>/frontend-users.git
cd tpi-compose
```

`users` **must** be on `feature/vault-secrets` (until it is merged). Built from `main`,
`users-service` ignores the password file and cannot reach MySQL.

## 2. Use a clean project name

```bash
export COMPOSE_PROJECT_NAME=vaulttest
```

If you ever ran this stack before, your old MySQL volume already holds the old root
password, and MySQL ignores the new one once it is initialized. A different project name
gives you fresh volumes and leaves your old data alone. (To keep the default name instead:
`docker compose down -v`, which deletes that data.)

## 3. Configure and start Vault

```bash
cp .env.example .env                       # VAULT_ADDR=https://host.docker.internal:8200
./vault/tls/gen-certs.sh                   # private CA + certificate (secrets/vault/tls, gitignored)
docker compose -f vault/server/docker-compose.yml up -d
docker ps --filter name=tpi-vault          # wait until tpi-vault says (healthy)
```

Vault initializes and unseals itself (`docker logs tpi-vault-init` shows "initialized", "unsealed").

## 4. Bootstrap (once)

Run this only when `docker ps --filter name=tpi-vault` says **healthy** (step 3), in the same
terminal and folder. It creates the account you will use to administer Vault, so it comes
before step 5.

```bash
docker compose -f vault/server/docker-compose.yml exec -T \
  -e BOOTSTRAP_OPERATORS="alice" -e OPERATOR_PASSWORD_alice='Local-Test-Pw-1' \
  vault-init sh /init/bootstrap.sh
```

What the command says:

- `BOOTSTRAP_OPERATORS="alice"`: the usernames to create, separated by spaces (`"ana luis"`).
  **`alice` is just an example: pick your own name** (lowercase letters, digits and underscore).
- `OPERATOR_PASSWORD_alice='...'`: that user's password. The variable name is
  `OPERATOR_PASSWORD_` followed by the username, so for `ana` it is `OPERATOR_PASSWORD_ana`.
  Pick your own password too.
- Prefer not to leave the password in the command? Drop the `OPERATOR_PASSWORD_...` part and
  change `-T` to `-it`: the script asks for each password on the keyboard.

It loads the policies, creates the AppRoles and the operator accounts, and revokes the root
token; it ends with `bootstrap done; root token revoked and deleted`. It runs **once**: running
it a second time refuses, because the root token is gone.

Keep the username and password: you use them in step 5 and to sign in to the UI (step 8).

## 5. Create the secrets and the Agents' credentials

```bash
export VAULT_USER=alice VAULT_PASSWORD='Local-Test-Pw-1'
./scripts/vault-seed-identity.sh           # MySQL password, JWT keys, admin and Grafana passwords
./scripts/vault-agent-creds.sh all         # one role_id + secret_id per Vault Agent
```

`VAULT_USER` and `VAULT_PASSWORD` must be **the ones you chose in step 4** (not necessarily
`alice`). If you leave them out, the scripts ask for them.

Nothing is printed except what was created. The first run pulls the Vault image if needed.

## 6. Start the application

```bash
docker compose up -d --build
```

The first build takes several minutes (it compiles `users` and `api-gateway` and builds the
front). Watch `docker ps`: the four `vault-agent-*` become `healthy` first; only then do
`mysql`, `dev-mailbox`, `users-service` and `grafana` start. Everything should end up healthy.

## 7. Check it

**No password in any container environment** (only `*_FILE` paths):

```bash
for c in mysql users-service dev-mailbox grafana; do
  echo "$c: $(docker inspect $c --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE 'PASSWORD|SECRET' | tr '\n' ' ')"
done
```

**The admin's password lives in Vault:**

```bash
bash -c 'set -a; . ./.env; set +a; . scripts/lib/vault.sh; vault_login; vault_cli kv get -mount=secret -field=password tpi/identity/bootstrap'
```

Open http://localhost:3000 and sign in as `admin@frc.utn.edu.ar` with that password. The 2FA
code is behind the mailbox button (bottom right). The very first login after starting the stack can
answer 503 (BCrypt on a cold JVM outlasts the gateway timeout): try again. The JWKS is at
http://localhost:3000/.well-known/jwks.json.

**Grafana:** http://localhost:3001, user `admin`, password from Vault
(`... -field=password tpi/identity/grafana`). The old `admin/admin` no longer works.

## 8. The Vault UI

https://localhost:8200/ui, method **Username**, with the operator you created in step 4 (`alice` in the
examples). The browser warns about
the certificate (private CA): accept it. As `alice` you see `tpi/identity/*`.

## 9. Try a team

```bash
./scripts/vault-onboard-team.sh demo bob
```

It prints what a team receives (role id, a wrapping token valid 10 minutes, the initial password of
`demo-bob`). Sign in to the UI as `demo-bob` with that password: the team can create and edit
`tpi/demo/env` (launch parameters and API keys) and gets "permission denied" on `tpi/identity/*`.
`alice` cannot read `tpi/demo/*`. How a team consumes it: [vault-teams.md](vault-teams.md).

## 10. Clean up

```bash
docker compose down -v
docker compose -f vault/server/docker-compose.yml down -v
rm -rf secrets/vault
```

## If something fails

| Symptom | Likely cause |
|---|---|
| A `vault-agent-*` stays `unhealthy` | Vault not reachable at `VAULT_ADDR`, step 5 not run, or the secret was never seeded. `docker logs vault-agent-users`. |
| `mysql` or `users-service` never starts | Waiting on its Agent (on purpose). Fix the Agent first. |
| `users-service` cannot connect to MySQL | An old MySQL volume (step 2), or `users` not on `feature/vault-secrets`. |
| `.env` errors about `VAULT_ADDR` | Step 3 skipped: `cp .env.example .env`. |
| "address already in use" | One of the ports above is taken. |
| First login answers 503 | Cold JVM; retry once. If it repeats every time, that is a real problem. |
| Browser asks to "select a certificate" | You have an older Vault: `git pull` and restart `tpi-vault`. |
| On Linux, `host.docker.internal` does not resolve on the host | Add it to `/etc/hosts` and set `VAULT_BIND_ADDR=0.0.0.0` for the server. |
