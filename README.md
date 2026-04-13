# FGFW

FGFW is a deployment and export toolkit for `xray` + `sing-box`.

It is designed for:
- VPS bootstrap and deployment
- unified config rendering
- export generation for clients
- SSH menu based operations

## Public repo scope

This public repository contains:
- deploy scripts
- templates
- domain groups
- safe example configuration
- menu and export logic

It does not contain:
- production secrets
- private keys
- residential proxy credentials
- generated subscription outputs
- local machine paths
- real server inventory

## Quick start

### Option A: clone the repo

```bash
git clone https://github.com/tuturuning/FGFW.git
cd FGFW
./deploy/install.sh validate
./deploy/install.sh menu
```

### Option B: bootstrap

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tuturuning/FGFW/main/bootstrap.sh)
```

## First files to edit

Before a real deployment, adjust these files:
- `deploy/config/app.env.example`
- `deploy/config/secrets.env.example`
- `deploy/config/targets.yaml`
- `deploy/config/nodes.yaml`
- `deploy/config/outbounds.yaml`
- `deploy/config/routing.yaml`

## Main entry points

```bash
./deploy/install.sh menu
./deploy/install.sh validate
./deploy/install.sh render
./deploy/install.sh apply --target demo-sg
./deploy/install.sh export
```

## SSH menu

FGFW provides a grouped SSH menu homepage:
- First Deploy
- Daily Ops
- Export
- Advanced
- Troubleshooting

The homepage also shows:
- server information
- core versions
- runtime status
- script version and upgrade hints

## Docs

- [Quick Start](docs/快速开始.md)
- [Config Guide](docs/配置说明.md)

## Safety note

Do not commit these to the public repo:
- `deploy/config/secrets.env`
- generated links or subscription files
- private keys or cert files
- real residential proxy credentials
