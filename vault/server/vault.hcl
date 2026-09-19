# Single-node Vault with integrated (Raft) storage and a TLS listener.
# api_addr / cluster_addr come from VAULT_API_ADDR / VAULT_CLUSTER_ADDR.

ui            = false
disable_mlock = true   # recommended with integrated storage (no swap concerns in a container)

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/server.pem"
  tls_key_file  = "/vault/tls/server-key.pem"
}
