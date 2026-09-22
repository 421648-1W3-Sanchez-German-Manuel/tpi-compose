# Vault for a team

How your team gets its secrets and launch parameters out of the shared Vault
without putting an SDK in your service. Identity runs Vault; you are a client of
it. Background: [vault-contract.md](vault-contract.md).

## What Identity gives you

After running `scripts/vault-onboard-team.sh <team> <member>...`, Identity sends you,
through a private channel:

| Item | What it is |
|---|---|
| `VAULT_ADDR` | Where Vault is (reached through Tailscale). |
| `role_id` | Your AppRole id. Not secret. |
| wrapping token | Valid 10 minutes, one use. Unwrapping it gives you your `secret_id`. |
| `ca.pem` | The CA that signed Vault's certificate. |
| `agent.hcl` | The Vault Agent config for your team. |
| a login | `<team>-<you>` and an initial password, for the UI and the CLI. |

Plus a tagged Tailscale auth key so your machine can reach Vault.

## One-time setup

```bash
mkdir .vault && cd .vault            # add .vault/ to .gitignore, NOW
# put ca.pem and agent.hcl here, then:
printf %s '<role_id>' > role_id
VAULT_ADDR=<addr> VAULT_CACERT=./ca.pem vault unwrap -field=secret_id <wrapping token> > secret_id
```

Unwrap within 10 minutes. If it expired or somebody used it first, ask Identity for a
new one (that is also how a `secret_id` is rotated). `.vault/` and `local-secrets/` never go
to git.

## Storing values

Everything lives under `secret/tpi/<team>/`. You can read and write all of it and
nothing outside it.

- **UI:** `<VAULT_ADDR>/ui`, sign in with method **Username** as `<team>-<you>`; change the
  password from the top-right menu. The browser warns about the certificate until you trust `ca.pem`.
- **CLI:** `VAULT_ADDR=<addr> VAULT_CACERT=./.vault/ca.pem vault login -method=userpass username=<team>-<you>`

Launch parameters and environment variables go in one secret, `secret/tpi/<team>/env`: one
key per variable, secrets and plain configuration alike.

```bash
vault kv put   -mount=secret tpi/<team>/env JAVA_OPTS='-Xmx512m' SPRING_PROFILES_ACTIVE=prod API_KEY=...
vault kv patch -mount=secret tpi/<team>/env API_KEY=new-value     # change ONE key
```

Careful: `kv put` replaces the whole secret; use `kv patch` to change or add a single key. In
the UI, each save creates a new version of the full secret.

## Using them

The Vault Agent renders `secret/tpi/<team>/env` as `/run/secrets/app.env`, one `KEY=value`
per line, plain dotenv (no quotes, no newlines inside a value). Your service never talks to Vault.

`vault/agent/load-env.sh` loads that file and runs your command. Values are taken
literally, so a `$` or a space in a secret is safe.

### In Docker on the mesh (verified on the real tailnet)

The Agent joins the network namespace of your Tailscale sidecar (the one from the
mesh skill, `vincular-tailscale-mesh`) and reaches Vault by MagicDNS name. No
`extra_hosts`, `dns`, `networks` or `ports` with `network_mode: "service:..."`;
the resolver comes from the same `resolv.conf` your micro already mounts.

```yaml
services:
  # `mesh` is your existing Tailscale sidecar (tag:microservicio).
  vault-agent:
    image: hashicorp/vault:2.1.1
    network_mode: "service:mesh"
    command: ["agent", "-config=/vault/agent.hcl"]
    environment:
      VAULT_ADDR: https://tpi-vault:8200
      VAULT_CACERT: /vault/ca.pem
    volumes:
      - ./.vault/agent.hcl:/vault/agent.hcl:ro
      - ./.vault/ca.pem:/vault/ca.pem:ro
      - ./.vault/auth:/vault/auth:ro     # role_id, secret_id
      - ./resolv.conf:/etc/resolv.conf:ro
      - app-secrets:/run/secrets
    healthcheck:
      test: ["CMD-SHELL", "test -s /run/secrets/app.env"]
      interval: 5s
      retries: 40
    depends_on:
      mesh: {condition: service_healthy}

  my-service:
    image: my-service
    network_mode: "service:mesh"
    entrypoint: ["/bin/sh", "/load-env.sh", "/run/secrets/app.env"]
    command: ["sh", "-c", "exec java $$JAVA_OPTS -jar app.jar"]
    volumes:
      - app-secrets:/run/secrets:ro
      - ./load-env.sh:/load-env.sh:ro    # copy of vault/agent/load-env.sh
    depends_on:
      vault-agent: {condition: service_healthy}

volumes:
  app-secrets:
    driver_opts: {type: tmpfs, device: tmpfs}
```

The CLI (storing values by hand) runs the same way, inside the mesh namespace:
`docker run --rm -it --network container:mesh -v ./resolv.conf:/etc/resolv.conf:ro -v ./.vault/ca.pem:/ca.pem:ro -e VAULT_ADDR=https://tpi-vault:8200 -e VAULT_CACERT=/ca.pem hashicorp/vault:2.1.1 vault login -method=userpass username=<team>-<you>`

### From your IDE (no Docker)

Run the Agent as a process (it is one static binary) with the destination pointed at a local
folder, and let the run configuration read the file:

```bash
sed 's#/run/secrets#./local-secrets#' .vault/agent.hcl > .vault/agent.local.hcl
VAULT_ADDR=<addr> VAULT_CACERT=./.vault/ca.pem vault agent -config=.vault/agent.local.hcl
```

In IntelliJ, an "EnvFile" run-configuration entry pointing at `local-secrets/app.env`; or, from a
shell, `sh vault/agent/load-env.sh local-secrets/app.env <your command>`. (In the local config, the
`role_id_file_path` and `secret_id_file_path` inside `agent.hcl` must point at `.vault/`.)

## Good to know

- The Agent re-renders within about 5 minutes of a change in Vault. A process reads its
  environment at start, so **restart the service** to pick up a new value.
- `app.env` is only as private as the process: the values are in its environment.
- To keep a secret as a file (a key, a certificate) instead of an environment variable, add a `template`
  block to `agent.hcl`; ask Identity if you want a hand.
- If Vault is down, running services keep working (the files are already there); a service that
  has to start needs Vault reachable.
