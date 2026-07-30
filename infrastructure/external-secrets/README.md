# External Secrets Operator

External Secrets Operator is managed through Argo CD using the official Helm
chart.

## GitOps ownership

lab01-root
  -> external-secrets Application
  -> External Secrets Helm chart

Runtime namespace: external-secrets
Helm chart version: 2.8.0
