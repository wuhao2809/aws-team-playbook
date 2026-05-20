# TeamGram

Capstone onboarding exercise for NEU. A shared "class wall" hosted on AWS where every student posts a self-intro after submitting a one-line Terraform PR that allowlists their IP.

**👉 Students: read [`../Collaboration Doc/TeamGram.md`](../Collaboration%20Doc/TeamGram.md) first.** That is the assignment. This README is for instructors and for students who want to understand the codebase after they finish the exercise.

---

## Repo layout

```
teamgram/
├── app/                  Flask API (containerized, runs on ECS Fargate)
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── lambda/               SQS consumer (writes posts to DynamoDB)
│   ├── handler.py
│   └── requirements.txt
├── terraform/            All infrastructure as code
│   ├── backend.tf        S3 + DynamoDB lock for shared state
│   ├── providers.tf
│   ├── variables.tf
│   ├── terraform.tfvars  ← THIS is the file students edit
│   ├── network.tf        VPC, subnets
│   ├── alb.tf            ALB + security group (the allowlist lives here)
│   ├── ecr.tf
│   ├── ecs.tf            Fargate service + IAM
│   ├── sqs_lambda.tf     SQS queue + Lambda consumer
│   ├── dynamodb.tf
│   └── outputs.tf
└── .github/workflows/
    ├── plan.yml          terraform plan on PR
    └── apply.yml         terraform apply + image build/push on merge to main
```

## One-time instructor setup

Before the first student opens a PR, an instructor must:

1. **Create the state backend manually** (chicken-and-egg — Terraform can't create its own backend):
   ```bash
   aws s3api create-bucket --bucket teamgram-tfstate-<unique> --region us-east-1
   aws s3api put-bucket-versioning --bucket teamgram-tfstate-<unique> \
     --versioning-configuration Status=Enabled
   aws dynamodb create-table --table-name teamgram-tflock \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```
   Then update `terraform/backend.tf` with the bucket name.

2. **Create a GitHub Actions IAM role** with OIDC trust to the class repo. Save its ARN as the `AWS_DEPLOY_ROLE_ARN` repo secret. Permissions needed: ECR push, ECS deploy, Lambda update, S3/DynamoDB on the state backend, plus the resource types Terraform manages.

3. **Seed `terraform.tfvars`** with the instructor's public IP so the wall is visible from day 1.

4. **First apply**, run manually from a workstation (just this one time):
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```
   After this, *only GitHub Actions ever applies*.

5. **Post the ALB DNS name** in the class Slack so students know where to go after their PR merges.

## What students actually do

See the full doc, but the TL;DR is:

1. Get their public IP from `checkip.amazonaws.com`.
2. Add `"x.x.x.x/32",  # Their Name` to `allowed_ips` in `terraform/terraform.tfvars`.
3. Open a PR. CI runs `terraform plan` and posts the diff.
4. Merge after review. CI runs `terraform apply`.
5. Visit the ALB URL and post their self-intro.

## How the request flow works

- `GET /` → ECS reads DynamoDB → renders HTML wall.
- `POST /intro` → ECS validates form → publishes to SQS → returns 200 immediately.
- SQS triggers Lambda → Lambda writes to DynamoDB.
- Next page load shows the new card.

The SQS+Lambda hop exists for pedagogy: it gives students who haven't taken distributed systems a concrete look at async processing, retries, and decoupling.

## Cost

Roughly $5–15/month idle (mostly ALB hours + Fargate task). Fits comfortably in AWS credits.
