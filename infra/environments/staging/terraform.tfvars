project_name    = "mnc-app"
environment     = "staging"
aws_region      = "ap-south-1"
aws_account_id  = "204803374292"

vpc_cidr             = "10.20.0.0/16"
public_subnet_cidrs  = ["10.20.1.0/24", "10.20.2.0/24"]
private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

ec2_key_name        = "mnc-app-keypair"
allowed_cidr_blocks = ["122.164.81.39/32"]

jenkins_ami_id        = "ami-0e267a9919cdf778f"
jenkins_instance_type = "t3.large"

kubernetes_version  = "1.35"
node_instance_types = ["t3.medium"]
capacity_type       = "SPOT"           # Staging can still use SPOT
desired_nodes       = 2
min_nodes           = 1
max_nodes           = 4

db_username       = "appuser"
db_instance_class = "db.t3.small"     # Slightly bigger than dev
db_storage        = 20

create_ecr = false  # ECR already created by dev environment
