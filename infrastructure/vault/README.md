# Vault

HashiCorp Vault deployed with the official Helm chart.

## Architecture

- Single Vault server
- Integrated Storage using Raft
- PersistentVolumeClaim using local-path
- Vault Agent Injector enabled
- Internal TLS temporarily disabled for the homelab
- Prepared for management through Argo CD

## Bootstrap material

Vault initialization material must never be committed to Git.

It is stored locally under:

```text
~/.vault-bootstrap/
```

Without auto-unseal, Vault must be unsealed after the pod or server is restarted.
