# ─────────────────────────────────────────────────────────────────────────────
# ROOT MODULE — infra/main.tf
#
# This file is called AS A MODULE by each environment's main.tf.
# It wires all sub-modules (vpc, eks, ecr, jenkins, rds) together.
#
# IMPORTANT: This file intentionally has NO terraform{} block and NO backend{}.
# The terraform{} block and backend{} live in environments/dev|staging|prod/main.tf.
# Terraform does not allow backend configuration in a called module — only in
# the root configuration (the directory you run terraform init from).
#
# Call chain:
#   environments/dev/main.tf  (has terraform{} + backend{} + providers)
#     └─► infra/main.tf       (this file — module logic only)
#           ├─► modules/vpc
#           ├─► modules/ec2-jenkins
#           ├─► modules/ecr
#           ├─► modules/eks
#           └─► modules/rds
# ─────────────────────────────────────────────────────────────────────────────

locals {
  cluster_name = "${var.project_name}-${var.environment}-cluster"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "devops"
    CostCenter  = var.cost_center
  }
}

# ── Module: VPC ───────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  tags                 = local.common_tags
}

# ── Module: Jenkins EC2 ───────────────────────────────────────────────────
# Jenkins is created BEFORE EKS so we can pass its SG ID to EKS.
module "jenkins" {
  source = "./modules/ec2-jenkins"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  vpc_cidr            = module.vpc.vpc_cidr
  private_subnet_id   = module.vpc.private_subnet_ids[0]
  public_subnet_ids   = module.vpc.public_subnet_ids
  availability_zone   = var.availability_zones[0]
  ami_id              = var.jenkins_ami_id
  instance_type       = var.jenkins_instance_type
  ec2_key_name        = var.ec2_key_name
  aws_region          = var.aws_region
  aws_account_id      = var.aws_account_id
  cluster_name        = local.cluster_name
  allowed_cidr_blocks = var.allowed_cidr_blocks
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.common_tags
}

# ── Module: ECR ───────────────────────────────────────────────────────────
# ECR is created once (from dev, create_ecr=true) and shared across all envs.
# staging/prod set create_ecr=false and reference the same repos by URL.
module "ecr" {
  source = "./modules/ecr"
  count  = var.create_ecr ? 1 : 0

  project_name      = var.project_name
  jenkins_role_arn  = module.jenkins.jenkins_role_arn
  eks_node_role_arn = module.eks.node_group_role_arn
  tags              = local.common_tags
}

# ── Module: EKS ───────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  project_name        = var.project_name
  environment         = var.environment
  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  jenkins_sg_id       = module.jenkins.jenkins_security_group_id
  alb_sg_id           = aws_security_group.alb.id
  ec2_key_name        = var.ec2_key_name
  node_instance_types = var.node_instance_types
  capacity_type       = var.capacity_type
  desired_nodes       = var.desired_nodes
  min_nodes           = var.min_nodes
  max_nodes           = var.max_nodes
  allowed_cidr_blocks = var.allowed_cidr_blocks
  tags                = local.common_tags
}

# ── Module: RDS ───────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  jenkins_sg_id      = module.jenkins.jenkins_security_group_id
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
  allocated_storage  = var.db_storage
  tags               = local.common_tags
}

# ── ALB Security Group ────────────────────────────────────────────────────
# Used by the EKS AWS Load Balancer Controller to front app traffic.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Application Load Balancer for ${var.environment}"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  })
}

# ── Kubernetes Namespace ──────────────────────────────────────────────────
# Creates the environment namespace inside the shared EKS cluster.
resource "kubernetes_namespace" "env" {
  metadata {
    name = var.environment
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
  depends_on = [module.eks]
}

# ── SSM Parameters ────────────────────────────────────────────────────────
# Stored here so Jenkins can read them without static credentials.
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.environment}/db/host"
  type  = "String"
  value = module.rds.db_host
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/${var.environment}/db/name"
  type  = "String"
  value = module.rds.db_name
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/${var.environment}/db/password"
  type  = "SecureString"
  value = var.db_password
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "/${var.project_name}/ecr/registry"
  type  = "String"
  value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  tags  = local.common_tags
}
