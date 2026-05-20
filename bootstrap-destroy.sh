#!/usr/bin/env bash
#
# TeamGram bootstrap teardown — undoes everything bootstrap.sh created
# *except* the GitHub OIDC provider (which is account-scoped and may
# be shared with other repos; re-running bootstrap.sh is idempotent
# against it).
#
# What this deletes:
#   - S3 state bucket (and ALL versioned object history)
#   - DynamoDB lock table
#   - ECR repo (and all images)
#   - IAM deploy role
#
# What this does NOT delete:
#   - GitHub OIDC identity provider (account-scoped, reusable)
#   - GitHub repo secrets (delete via `gh secret delete` or the UI)
#   - The app stack (ALB / ECS / SQS / Lambda / DynamoDB posts table /
#     VPC / IAM roles for the app) — run `terraform destroy` first.
#
# Set CONFIRM=DESTROY to skip the interactive prompt (used by CI).

set -euo pipefail

PROJECT="teamgram"
REGION="${AWS_REGION:-us-west-2}"
LOCK_TABLE="${PROJECT}-tflock"
ECR_REPO="${PROJECT}-app"
ROLE_NAME="${PROJECT}-gha-deploy"

c_blue=$'\033[0;34m'; c_green=$'\033[0;32m'; c_yellow=$'\033[0;33m'
c_red=$'\033[0;31m';  c_reset=$'\033[0m'
step() { echo "${c_blue}==>${c_reset} $*"; }
ok()   { echo "  ${c_green}✓${c_reset} $*"; }
warn() { echo "  ${c_yellow}!${c_reset} $*"; }
die()  { echo "${c_red}error:${c_reset} $*" >&2; exit 1; }

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
done
aws sts get-caller-identity >/dev/null 2>&1 || die "aws CLI not authenticated."
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

step "Target"
ok "AWS account: $ACCOUNT  (region $REGION)"

if [ "${CONFIRM:-}" != "DESTROY" ]; then
  echo
  echo "${c_red}This will permanently delete the bootstrap resources above.${c_reset}"
  echo "Make sure you ran 'terraform destroy' on the app stack first."
  echo
  read -r -p "Type 'DESTROY' to confirm: " confirm
  [ "$confirm" = "DESTROY" ] || die "aborted."
fi

# ---- 1. S3 state bucket (purge all versions, then delete) --------------------
step "S3 state bucket"
BUCKET="$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '${PROJECT}-tfstate-')].Name | [0]" \
  --output text)"
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  while true; do
    page="$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 \
      --query '{V:Versions[].{Key:Key,VersionId:VersionId},D:DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null || echo '{}')"
    versions="$(echo "$page" | jq -c '.V // []')"
    markers="$(echo "$page"  | jq -c '.D // []')"
    [ "$versions" = "[]" ] && [ "$markers" = "[]" ] && break
    if [ "$versions" != "[]" ]; then
      aws s3api delete-objects --bucket "$BUCKET" \
        --delete "{\"Objects\":$versions,\"Quiet\":true}" >/dev/null
    fi
    if [ "$markers" != "[]" ]; then
      aws s3api delete-objects --bucket "$BUCKET" \
        --delete "{\"Objects\":$markers,\"Quiet\":true}" >/dev/null
    fi
  done
  aws s3api delete-bucket --bucket "$BUCKET" >/dev/null
  ok "deleted bucket $BUCKET"
else
  warn "no ${PROJECT}-tfstate-* bucket found"
fi

# ---- 2. DynamoDB lock table --------------------------------------------------
step "DynamoDB lock table"
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null
  ok "deleted table $LOCK_TABLE"
else
  warn "table $LOCK_TABLE not found"
fi

# ---- 3. ECR repo (force = also nukes images) ---------------------------------
step "ECR repository"
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force >/dev/null
  ok "deleted ECR repo $ECR_REPO"
else
  warn "ECR repo $ECR_REPO not found"
fi

# ---- 4. IAM deploy role ------------------------------------------------------
# Done LAST: deleting the role can invalidate the STS session that's
# making these calls, so any later step might fail.
step "IAM deploy role"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn' --output text \
    | tr '\t' '\n' | while read -r arn; do
        [ -z "$arn" ] && continue
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
      done
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null
  ok "deleted role $ROLE_NAME"
else
  warn "role $ROLE_NAME not found"
fi

cat <<EOF

${c_green}Bootstrap teardown complete.${c_reset}

What's left in the account:
  - GitHub OIDC provider (harmless; reusable by future bootstraps)

What's left in GitHub:
  - Repo secrets AWS_DEPLOY_ROLE_ARN, TF_STATE_BUCKET, TF_LOCK_TABLE.
    They now point at deleted resources. Either:
      gh secret delete AWS_DEPLOY_ROLE_ARN --repo <owner>/<repo>
      gh secret delete TF_STATE_BUCKET     --repo <owner>/<repo>
      gh secret delete TF_LOCK_TABLE       --repo <owner>/<repo>
    or just re-run ./bootstrap.sh and they'll be overwritten.
EOF
