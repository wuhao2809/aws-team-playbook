# Shared remote state. The S3 bucket and DynamoDB lock table must be
# created manually before the first `terraform init` (see README).
#
# WHY: when six teams share an AWS account, they MUST share a single
# Terraform state file. The DynamoDB lock prevents two students from
# applying at the same time — the second `apply` will block until the
# first releases the lock.

terraform {
  backend "s3" {
    bucket         = "teamgram-tfstate-CHANGEME"
    key            = "teamgram/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "teamgram-tflock"
    encrypt        = true
  }
}
