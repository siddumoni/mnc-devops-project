output "repository_urls" {
  description = "Map of repository name → ECR URL. Used in Jenkins to push images."
  value       = { for k, v in aws_ecr_repository.app : k => v.repository_url }
}

output "registry_id" {
  value = values(aws_ecr_repository.app)[0].registry_id
}
