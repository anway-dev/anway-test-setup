# Anway test setup

The cloud / end-to-end **test environment** for [Anway](https://github.com/anway-dev/anway) —
a realistic, deployable software organisation that Anway connects to and
operates on. It stands up a fleet of microservices, observability, CI/CD, and
chaos + traffic generators so you can exercise Anway's connectors, incident
flows and agents against something that behaves like a real org.

> Not the Anway product — this is the *system under test*. Deploy it, point
> Anway's connectors at it, and watch real alerts, deploys and incidents flow.

## What's inside

```
services/     14 mock microservices (auth, cart, order, payment, product,
              inventory, shipping, search, review, analytics, notification,
              recommendation, admin, api-gateway) — emit metrics/logs/traces
runners/      chaos-runner       — injects failures (latency, errors, OOM)
              traffic-simulator  — drives realistic load / user journeys
k8s/          manifests — local, namespaces, observability, runners,
              services, spinnaker
terraform/    AWS infra — EKS, VPC, RDS, Redis (ElastiCache), ECR, IRSA,
              Secrets Manager
scripts/      deploy.sh · local-k8s.sh · local-orbstack.sh
.github/      CI (build & push images) + CD (notify Anway deploy gate)
```

## Run it locally (OrbStack / any k8s)

```bash
cp .env.example .env.local     # then fill in the values
source .env.local
./scripts/local-orbstack.sh    # or ./scripts/local-k8s.sh
```

**Prerequisites:** OrbStack (or any local k8s) with Kubernetes enabled, plus
`docker`, `kubectl` and `helm` on your PATH.

This deploys the services, observability stack, and the chaos/traffic runners
into your local cluster — enough to generate live signals for Anway.

## Deploy to AWS (EKS)

```bash
cd terraform
terraform init && terraform apply     # provisions EKS, VPC, RDS, Redis, ECR, secrets

cd ..
cp .env.example .env                   # fill AWS + TF vars
source .env
./scripts/deploy.sh                    # bootstraps k8s manifests onto the cluster
```

The CD workflow (`.github/workflows/cd.yaml`) notifies Anway's deploy gate on
each release, so deploys show up as events inside Anway.

## Configuration

Copy `.env.example` and set your own values — **never commit `.env` / `.env.local`**
(both are gitignored). Keys include:

| Variable | Purpose |
|----------|---------|
| `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN` | AWS target + deploy role |
| `TF_BACKEND_BUCKET`, `TF_BACKEND_REGION` | Terraform remote state |
| `TF_VAR_db_password`, `TF_VAR_jwt_secret`, `TF_VAR_grafana_admin_password`, `TF_VAR_spinnaker_ui_password` | Secrets passed to Terraform (stored in AWS Secrets Manager, not the repo) |
| `ANWAY_WEBHOOK_URL`, `ANWAY_WEBHOOK_TOKEN` | Where deploy/incident events are POSTed into Anway |

Secrets on the cluster are pulled at runtime from AWS Secrets Manager via the
External Secrets Operator + IRSA — nothing sensitive lives in this repo.

## Related

- **[anway-dev/anway](https://github.com/anway-dev/anway)** — the Anway platform itself.
