# ─────────────────────────────────────────────
# RDS MODULE
# MySQL RDS instance per environment.
# Placed in private subnets, accessible only
# from EKS node security group.
# ─────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "RDS MySQL allow from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
    description     = "MySQL from EKS pods only"
  }

  # Also allow from Jenkins for schema migrations during deployment
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.jenkins_sg_id]
    description     = "MySQL from Jenkins for Flyway migrations"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  })
}

# ── RDS Parameter Group (MySQL 8.0 tuning) ───────────────────────────────
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-${var.environment}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = var.tags
}

# ── RDS Instance ─────────────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-${var.environment}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class  # db.t3.micro for dev, db.t3.small for staging/prod

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 3  # Auto-scaling storage up to 3x

  db_name  = replace("${var.project_name}_${var.environment}", "-", "_")
  username = var.db_username
  password = var.db_password  # In real prod: use aws_secretsmanager_secret

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  # These are CRITICAL for banking/production setups:
  backup_retention_period   = var.environment == "prod" ? 30 : 7
  backup_window             = "03:00-04:00"  # 3-4 AM UTC (low traffic)
  maintenance_window        = "Mon:04:00-Mon:05:00"
  deletion_protection       = var.environment == "prod" ? true : false
  skip_final_snapshot       = var.environment == "prod" ? false : true
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-prod-final-snapshot" : null
  storage_encrypted         = true  # Encryption at rest mandatory for PCI-DSS
  multi_az                  = var.environment == "prod" ? true : false  # HA for prod

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-mysql"
  })
}
