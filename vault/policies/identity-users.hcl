# users-service: database password, JWT signing keys, initial admin password.

path "secret/data/tpi/identity/db"        { capabilities = ["read"] }
path "secret/data/tpi/identity/jwt"       { capabilities = ["read"] }
path "secret/data/tpi/identity/bootstrap" { capabilities = ["read"] }
