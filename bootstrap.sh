#!/usr/bin/env bash
#
# TeamGram bootstrap — run ONCE per team, on the first day.
#
# Creates everything needed before GitHub Actions can deploy:
#   - S3 bucket for Terraform state (uniquely named per team)
#   - DynamoDB table for state locking
#   - ECR repo for the app container
#   - GitHub OIDC provider in the AWS account
#   - IAM role GH Actions assumes
#   - GitHub repo secrets pointing CI at all of the above
#   - Local terraform/backend.hcl for local plans
#
# Idempotent: re-running it is safe; existing resources are left alone.

set -euo pipefail

PROJECT="teamgram"
REGION="${AWS_REGION:-us-west-2}"
LOCK_TABLE="${PROJECT}-tflock"
ECR_REPO="${PROJECT}-app"
ROLE_NAME="${PROJECT}-gha-deploy"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ---- pretty printing ----------------------------------------------------------
c_blue=$'\033[0;34m'; c_green=$'\033[0;32m'; c_yellow=$'\033[0;33m'
c_red=$'\033[0;31m';  c_reset=$'\033[0m'
step() { echo "${c_blue}==>${c_reset} $*"; }
ok()   { echo "  ${c_green}✓${c_reset} $*"; }
warn() { echo "  ${c_yellow}!${c_reset} $*"; }
die()  { echo "${c_red}error:${c_reset} $*" >&2; exit 1; }

# ---- 1. preflight -------------------------------------------------------------
step "Preflight checks"
for bin in aws gh terraform jq git; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
done
ok "all required CLIs present"

aws sts get-caller-identity >/dev/null 2>&1 || die "aws CLI not authenticated. Run 'aws configure' or export AWS credentials."
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run 'gh auth login'."

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO_FULL" ] || die "could not resolve GitHub repo. Run this from inside a cloned repo with 'gh' configured."

ok "AWS account:  $ACCOUNT  (region $REGION)"
ok "GitHub repo:  $REPO_FULL"
echo
read -r -p "Bootstrap this account/repo? Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || die "aborted."

# ---- 2. S3 state bucket -------------------------------------------------------
step "S3 state bucket"
BUCKET=""
# look for an existing bucket we made earlier
EXISTING="$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT}-tfstate-')].Name | [0]" --output text)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  BUCKET="$EXISTING"
  ok "reusing existing bucket: $BUCKET"
else
  SUFFIX="$(openssl rand -hex 4)"
  BUCKET="${PROJECT}-tfstate-${SUFFIX}"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  ok "created bucket: $BUCKET"
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled >/dev/null
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
ok "versioning + encryption + public-access-block applied"

# ---- 3. DynamoDB lock table ---------------------------------------------------
step "DynamoDB lock table"
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  ok "table $LOCK_TABLE already exists"
else
  aws dynamodb create-table --table-name "$LOCK_TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
  ok "created table $LOCK_TABLE"
fi

# ---- 4. ECR repo --------------------------------------------------------------
step "ECR repository"
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  ok "ECR repo $ECR_REPO already exists"
else
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true >/dev/null
  ok "created ECR repo $ECR_REPO"
fi

# ---- 5. GitHub OIDC provider --------------------------------------------------
step "GitHub OIDC identity provider"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  ok "OIDC provider already exists"
else
  # AWS no longer requires the thumbprint when the IdP is GitHub Actions,
  # but the API still demands a value — any 40-char hex string works.
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "ffffffffffffffffffffffffffffffffffffffff" >/dev/null
  ok "created OIDC provider"
fi

# ---- 6. IAM deploy role -------------------------------------------------------
step "IAM deploy role"
TRUST_FILE="$(mktemp)"
sed -e "s|__ACCOUNT__|${ACCOUNT}|g" -e "s|__REPO__|${REPO_FULL}|g" \
  bootstrap/iam-trust-policy.json.tmpl > "$TRUST_FILE"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_FILE" >/dev/null
  ok "updated trust policy on existing role $ROLE_NAME"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
  ok "created role $ROLE_NAME"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
ok "AdministratorAccess attached (sandbox-scoped)"
rm -f "$TRUST_FILE"

# ---- 7. GitHub repo secrets ---------------------------------------------------
step "GitHub repo secrets"
echo -n "$ROLE_ARN" | gh secret set AWS_DEPLOY_ROLE_ARN --repo "$REPO_FULL" --body - >/dev/null
echo -n "$BUCKET"   | gh secret set TF_STATE_BUCKET     --repo "$REPO_FULL" --body - >/dev/null
echo -n "$LOCK_TABLE" | gh secret set TF_LOCK_TABLE     --repo "$REPO_FULL" --body - >/dev/null
ok "AWS_DEPLOY_ROLE_ARN, TF_STATE_BUCKET, TF_LOCK_TABLE set"

# ---- 8. local backend.hcl -----------------------------------------------------
step "Local backend.hcl"
cat > terraform/backend.hcl <<EOF
bucket         = "${BUCKET}"
dynamodb_table = "${LOCK_TABLE}"
region         = "${REGION}"
EOF
ok "wrote terraform/backend.hcl (gitignored)"

# ---- done ---------------------------------------------------------------------
cat <<EOF

${c_green}Bootstrap complete.${c_reset}

Next steps:
  1. Edit terraform/terraform.tfvars and add your /32 IP.
       (find it at https://checkip.amazonaws.com/)
  2. Commit and push to main.
  3. Watch the GitHub Actions 'terraform-apply' run.
  4. Once green, the run prints the ALB URL — visit it to see the wall.

For local debugging:
  cd terraform && terraform init -backend-config=backend.hcl && terraform plan

EOF
