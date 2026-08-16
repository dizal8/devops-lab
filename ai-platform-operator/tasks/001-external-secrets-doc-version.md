# Task 001 — External Secrets documentation version drift

Risk: GREEN

## Objective

Find repository documentation that incorrectly states that External Secrets
uses chart version 2.8.0 while the GitOps Application currently declares 2.9.0.

Correct documentation only.

## Allowed changes

- Documentation files only.
- References to the outdated External Secrets chart version may be changed
  from 2.8.0 to 2.9.0 where repository evidence proves that 2.9.0 is current.

## Forbidden changes

Do NOT modify:

- Kubernetes manifests
- Argo CD Applications
- Helm values
- Terraform
- Vault
- RBAC
- NetworkPolicy
- CI workflows
- scripts
- secrets
- cluster resources

Do NOT:

- execute kubectl mutations
- execute helm mutations
- push to main
- merge to main

## Validation

The final diff must contain documentation-only changes.

Confirm that:

1. the GitOps Application declares External Secrets 2.9.0;
2. outdated documentation references are corrected;
3. no infrastructure configuration changed.
