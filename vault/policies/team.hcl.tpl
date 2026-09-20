# Template of the policy of team __TEAM__ (rendered by scripts/vault-onboard-team.sh
# into a policy called team-__TEAM__). Not loaded by bootstrap: it is not a *.hcl.
#
# A team reads and writes everything under its own namespace, and only reads the
# client secret Identity issued to it.

path "secret/data/tpi/__TEAM__/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/tpi/__TEAM__/*" { capabilities = ["read", "list", "delete"] }

path "secret/data/tpi/shared/clients/__TEAM__" { capabilities = ["read"] }
