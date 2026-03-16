output "vpc_id"                 { value = module.vpc.vpc_id }
output "cluster_name"           { value = module.eks.cluster_name }
output "cluster_endpoint"       { value = module.eks.cluster_endpoint }
output "cluster_ca_certificate" { value = module.eks.cluster_ca_certificate }
output "jenkins_alb_dns"        { value = module.jenkins.jenkins_alb_dns }
output "sonarqube_url"          { value = module.jenkins.sonarqube_url }
output "db_endpoint"            { value = module.rds.db_endpoint }
output "ecr_repository_urls" {
  value = var.create_ecr ? module.ecr[0].repository_urls : {}
}
