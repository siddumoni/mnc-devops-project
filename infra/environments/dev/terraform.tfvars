# ─────────────────────────────────────────────
# DEV ENVIRONMENT — terraform.tfvars
#
# Usage:
#   cd infra/environments/dev
#   terraform init -backend-config="key=environments/dev/terraform.tfstate"
#   terraform apply -var-file="terraform.tfvars" -var="db_password=YourSecurePass123!"
#
# NEVER commit db_password to git. Pass it via:
#   - CI/CD secret variable
#   - AWS SSM at apply time
#   - terraform.tfvars.local (gitignored)
# ─────────────────────────────────────────────

project_name    = "mnc-app"
environment     = "dev"
aws_region      = "ap-south-1"
aws_account_id  = "204803374292"   # ← Replace with your account ID

# Networking — dev gets its own /16 CIDR to avoid conflicts
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]
private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

# Access
ec2_key_name        = "mnc-app-keypair"         # ← Create this key pair in EC2 console first
allowed_cidr_blocks = ["122.164.85.165/32"]      # ← Replace with your actual IP

# Jenkins
jenkins_ami_id       = "ami-0fe1d8d9040df33e6"  # Amazon Linux 2023 — ap-south-1
jenkins_instance_type = "t3.large"              # 2 vCPU, 8 GB — sufficient for dev builds

# EKS
kubernetes_version  = "1.35"
node_instance_types = ["t3.medium"]             # Dev: smaller nodes, lower cost
capacity_type       = "SPOT"                    # Dev uses SPOT instances to save ~70% cost
desired_nodes       = 2
min_nodes           = 1
max_nodes           = 3

# RDS — dev uses smallest possible instance
db_username      = "appuser"
db_instance_class = "db.t3.micro"
db_storage       = 20

# ECR is created ONCE from dev, reused by staging and prod
create_ecr = true
