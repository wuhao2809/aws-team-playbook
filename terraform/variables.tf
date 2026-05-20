variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "teamgram"
}

# THE list students will modify. Each entry is a CIDR — use /32 for a
# single IP. Add a comment with your name so reviewers know who's who.
variable "allowed_ips" {
  description = "CIDRs allowed to reach the ALB. Add your /32 here via PR."
  type        = list(string)
}

variable "image_tag" {
  description = "ECR image tag to deploy. CI overrides this with the commit SHA."
  type        = string
  default     = "latest"
}
