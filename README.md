# TeamGram — Capstone AWS Playbook

A template repo each capstone team copies into their own private GitHub repo and deploys to their own AWS Innovation Sandbox lease. After a one-time `./bootstrap.sh`, the team works through PRs: each member edits a single line in `terraform.tfvars` to add their IP, opens a PR, gets it reviewed, merges, and GitHub Actions deploys.

**👉 Students: read [`../Collaboration Doc/TeamGram.md`](../Collaboration%20Doc/TeamGram.md) first.** That is the assignment narrative. This README is the operational guide for whoever runs `bootstrap.sh` (typically the team lead on day 1).

---

## What you get

```
                                 Internet
                                    │
                                    ▼
                  ALB (security group: allowlisted IPs only)
                                    │
                                    ▼
                       ECS Fargate (Flask, from ECR)
                          │                 │
                  GET / read              POST /intro enqueue
                          │                 │
                          ▼                 ▼
                      DynamoDB ◀──── Lambda ◀──── SQS
```

Plus: S3 + DynamoDB lock for shared Terraform state, and an OIDC IAM role that GitHub Actions assumes to deploy.

## Repo layout

```
teamgram/
├── bootstrap.sh                 ONE-time setup script
├── bootstrap/
│   └── iam-trust-policy.json.tmpl
├── app/                         Flask API (containerized, on ECS)
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── lambda/                      SQS consumer
│   ├── handler.py
│   └── requirements.txt
├── terraform/
│   ├── backend.tf               partial backend (filled by backend.hcl)
│   ├── providers.tf
│   ├── variables.tf
│   ├── terraform.tfvars         ← THE FILE STUDENTS EDIT
│   ├── network.tf               VPC + subnets
│   ├── alb.tf                   ALB + the IP allowlist SG
│   ├── ecs.tf                   Fargate service + IAM
│   ├── sqs_lambda.tf            queue + Lambda + event mapping
│   ├── dynamodb.tf
│   └── outputs.tf
└── .github/workflows/
    ├── plan.yml                 terraform plan on PR
    └── apply.yml                build image + terraform apply on merge
```

## Day-1 setup (team lead, ~5 minutes)

Prerequisites on your laptop:

- AWS CLI authenticated to your team's sandbox lease (`aws sts get-caller-identity` should print the sandbox account ID)
- GitHub CLI authenticated to the GitHub account that owns the team repo (`gh auth status`)
- `terraform`, `jq`, `git`, `openssl` installed

Then:

```bash
# 1. Create your team's repo from this template, then clone it
gh repo create your-org/your-team-teamgram --template wuhao2809/aws-team-playbook --private --clone
cd your-team-teamgram

# 2. Bootstrap your sandbox
./bootstrap.sh
```

`bootstrap.sh` is idempotent — re-run it any time. It creates:

| AWS resource | Purpose |
|---|---|
| S3 bucket `teamgram-tfstate-<random>` | Terraform remote state |
| DynamoDB table `teamgram-tflock` | Terraform state lock |
| ECR repo `teamgram-app` | container registry for the Flask image |
| OIDC identity provider | lets GitHub Actions assume an AWS role |
| IAM role `teamgram-gha-deploy` | the role CI assumes (AdministratorAccess, scoped to your repo + sandbox) |

…and sets these GitHub repo secrets:

| Secret | Used by |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | both workflows for OIDC auth |
| `TF_STATE_BUCKET` | both workflows to fill the partial backend |
| `TF_LOCK_TABLE` | both workflows to fill the partial backend |

## Day-1, second step (team lead)

Seed the IP allowlist with your own IP so you can confirm the wall works:

```bash
# get your public IP
curl -s https://checkip.amazonaws.com/

# edit terraform/terraform.tfvars and add your /32 line
git add terraform/terraform.tfvars
git commit -m "Seed allowlist with team-lead IP"
git push origin main
```

Watch the **terraform-apply** workflow run in the Actions tab. When it succeeds, the last step prints the ALB URL. Open it in your browser — you should see the (empty) wall.

## After day 1 (every other student)

Each teammate adds their IP via PR. See `../Collaboration Doc/TeamGram.md` for the full student-facing flow.

## Local development

You don't need to run anything locally — CI does it all. But for debugging Terraform plans:

```bash
cd terraform
terraform init -backend-config=backend.hcl   # backend.hcl was written by bootstrap.sh
terraform plan
```

`backend.hcl` is gitignored — it lives only on your laptop.

## Cost

Roughly $5–15/month idle (mostly ALB hours + 1 Fargate task). Fits comfortably in sandbox credits.

## Cleanup (end of semester)

```bash
cd terraform
terraform destroy -var "image_tag=latest"
```

Then either let the sandbox lease expire (everything goes with it) or manually empty the state bucket and delete the bootstrap resources.
