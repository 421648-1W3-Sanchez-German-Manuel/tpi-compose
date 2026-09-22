# Single-node Vault with integrated (Raft) storage and a TLS listener.
# api_addr / cluster_addr come from VAULT_API_ADDR / VAULT_CLUSTER_ADDR.

ui            = true
disable_mlock = true   # recommended with integrated storage (no swap concerns in a container)

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/server.pem"
  tls_key_file  = "/vault/tls/server-key.pem"
  # Clients authenticate with AppRole or userpass, never with a certificate. Without
  # this the server asks every client for one, and browsers pop up a "select a
  # certificate" dialog before showing the UI.
  tls_disable_client_certs = true
}
