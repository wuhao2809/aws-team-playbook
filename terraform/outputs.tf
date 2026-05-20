output "alb_dns_name" {
  description = "Public URL of the TeamGram wall."
  value       = "http://${aws_lb.main.dns_name}/"
}

output "ecr_repository_url" {
  description = "Where CI pushes the container image."
  value       = data.aws_ecr_repository.app.repository_url
}
