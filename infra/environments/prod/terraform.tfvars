project_name    = "mnc-app"
environment     = "prod"
aws_region      = "ap-south-1"
aws_account_id  = "204803374292"

vpc_cidr             = "10.30.0.0/16"
public_subnet_cidrs  = ["10.30.1.0/24", "10.30.2.0/24"]
private_subnet_cidrs = ["10.30.10.0/24", "10.30.11.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

ec2_key_name        = "mnc-app-keypair"
allowed_cidr_blocks = ["122.164.85.165/32"]

jenkins_ami_id        = "ami-0fe1d8d9040df33e6"
jenkins_instance_type = "t3.large"

kubernetes_version  = "1.35"
node_instance_types = ["t3.large"]    # Bigger nodes for prod workloads
capacity_type       = "ON_DEMAND"     # NEVER use SPOT for prod — unpredictable termination
desired_nodes       = 3               # 3 nodes for availability across 2 AZs
min_nodes           = 2               # Never go below 2 — one per AZ minimum
max_nodes           = 8

db_username       = "appuser"
db_instance_class = "db.t3.small"    # Upgrade to db.r6g.large for real prod
db_storage        = 50

create_ecr = false
