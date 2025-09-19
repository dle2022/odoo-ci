# Odoo On-Prem CI/CD (Prod + Staging)

This repo gives you an Odoo.sh-like workflow on-prem using:
- GitHub (branches: `main` → Production, `staging` → Staging)
- Docker Compose (separate stacks for prod & staging)
- GitHub Actions (self-hosted runner with label `odoo-ci`)
- Automated DB + filestore backups
- Nginx reverse proxy + TLS (Let's Encrypt)

See scripts in `scripts/` and `backup/`, Compose files in `compose/`.
CI test Fri Sep 19 01:58:20 AM UTC 2025
