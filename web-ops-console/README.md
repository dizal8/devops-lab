# DZL Web Ops Console

Responsive browser administration interface for devops-lab.

## Access

Tailnet only through Tailscale Serve.

## Services

- `/` responsive management UI
- `/terminal/` ttyd shell

## Security

- ttyd listens only on 127.0.0.1
- no Tailscale Funnel
- HTTPS through Tailscale Serve
- shell runs as user `dizal`
