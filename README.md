# FGFW

FGFW is a deployment and export toolkit for `xray` + `sing-box`.

This public repository contains:
- deploy scripts
- templates
- domain groups
- safe example configuration

It does not contain:
- production secrets
- private keys
- residential proxy credentials
- generated subscription outputs
- local machine paths

## Quick start

```bash
git clone https://github.com/tuturuning/FGFW.git
cd FGFW
./deploy/install.sh validate
./deploy/install.sh menu
```

For real deployment, copy and edit:
- `deploy/config/app.env.example`
- `deploy/config/secrets.env.example`
- `deploy/config/targets.yaml`
- `deploy/config/nodes.yaml`
- `deploy/config/outbounds.yaml`

## Entry points

```bash
./deploy/install.sh menu
./deploy/install.sh validate
./deploy/install.sh render
./deploy/install.sh apply --target demo-sg
```
