# External Secrets Operator - read-only KV v2 access

path "secret/data/lab/*" {
  capabilities = ["read"]
}

path "secret/metadata/lab/*" {
  capabilities = ["read", "list"]
}

path "secret/data/devops-lab/*" {
  capabilities = ["read"]
}

path "secret/metadata/devops-lab/*" {
  capabilities = ["read", "list"]
}
