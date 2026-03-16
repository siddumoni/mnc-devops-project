# environments/staging/main.tf
# Calls the root module with staging-specific values.
# The real logic lives in ../../main.tf

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }

  # Separate state file for staging — never share state between environments
  backend "s3" {
    bucket = "mnc-app-terraform-state-204803374292"   # bootstrap.sh patches this with the real bucket name
    key            = "environments/staging/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.staging.cluster_endpoint
  cluster_ca_certificate = base64decode(module.staging.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "mnc-app-staging-cluster"]
  }
}

module "staging" {
  source = "../../"

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = var.aws_region
  aws_account_id        = var.aws_account_id
  cost_center           = var.cost_center
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  availability_zones    = var.availability_zones
  ec2_key_name          = var.ec2_key_name
  jenkins_ami_id        = var.jenkins_ami_id
  jenkins_instance_type = var.jenkins_instance_type
  allowed_cidr_blocks   = var.allowed_cidr_blocks
  kubernetes_version    = var.kubernetes_version
  node_instance_types   = var.node_instance_types
  capacity_type         = var.capacity_type
  desired_nodes         = var.desired_nodes
  min_nodes             = var.min_nodes
  max_nodes             = var.max_nodes
  db_username           = var.db_username
  db_password           = var.db_password
  db_instance_class     = var.db_instance_class
  db_storage            = var.db_storage
  create_ecr            = var.create_ecr
  acm_certificate_arn   = var.acm_certificate_arn
}

# ── Pass-through outputs so terraform output works from this folder ────────
output "vpc_id"              { value = module.staging.vpc_id }
output "cluster_name"        { value = module.staging.cluster_name }
output "cluster_endpoint"    { value = module.staging.cluster_endpoint }
output "cluster_ca_certificate" { value = module.staging.cluster_ca_certificate }
output "jenkins_alb_dns"     { value = module.staging.jenkins_alb_dns }
output "sonarqube_url"       { value = module.staging.sonarqube_url }
output "db_endpoint"         { value = module.staging.db_endpoint }
output "ecr_repository_urls" { value = module.staging.ecr_repository_urls }
