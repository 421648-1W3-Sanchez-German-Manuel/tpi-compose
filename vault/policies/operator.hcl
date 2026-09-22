# Identity operators. They administer Vault and own the identity namespace.
# Deliberately NO access to secret/tpi/<team>/*: other teams' private paths stay
# unreadable for us too.

path "sys/policies/acl"            { capabilities = ["list"] }
path "sys/policies/acl/*"          { capabilities = ["create", "read", "update", "delete", "list"] }

path "auth/approle/role"           { capabilities = ["list"] }
path "auth/approle/role/*"         { capabilities = ["create", "read", "update", "delete", "list"] }

path "auth/userpass/users"         { capabilities = ["list"] }
path "auth/userpass/users/*"       { capabilities = ["create", "read", "update", "delete", "list"] }

path "sys/auth"                    { capabilities = ["read"] }
path "sys/mounts"                  { capabilities = ["read"] }

path "secret/data/tpi/identity/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/tpi/identity/*" { capabilities = ["read", "list"] }

path "secret/data/tpi/shared/clients/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/tpi/shared/clients/*" { capabilities = ["read", "list"] }
