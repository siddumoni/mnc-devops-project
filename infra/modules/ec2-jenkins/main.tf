# ─────────────────────────────────────────────
# EC2-JENKINS MODULE
# Provisions the Jenkins master EC2 instance.
# User data script installs:
#   - Java 17, Jenkins, Maven, Docker,
#     kubectl, aws-cli, SonarQube (Docker)
#
# In an MNC you'd also have separate agent
# nodes (or EKS-based dynamic agents), but
# for this lab the master handles everything.
# ─────────────────────────────────────────────

# ── IAM Role for Jenkins EC2 (replaces static AWS keys) ──────────────────
resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

# Jenkins needs: ECR push/pull, EKS describe, SSM for secrets
resource "aws_iam_policy" "jenkins" {
  name        = "${var.project_name}-jenkins-policy"
  description = "Permissions Jenkins needs to build and deploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.project_name}/*"
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.project_name}/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins" {
  policy_arn = aws_iam_policy.jenkins.arn
  role       = aws_iam_role.jenkins.name
}

# SSM agent (so you can shell in without SSH keys exposed publicly)
resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.jenkins.name
}

# ── Security Group ────────────────────────────────────────────────────────
resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins master - allow 8080 from VPN/bastion only"
  vpc_id      = var.vpc_id

  # Jenkins UI — restrict to your office/VPN IP in production
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Jenkins UI access"
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Jenkins UI access from ALB within VPC"
  }

  # SSH — only from within VPC (e.g. bastion host)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "SSH from within VPC only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Jenkins needs outbound for GitHub, ECR, EKS, SonarQube"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-sg"
  })
}

# ── EBS Volume for Jenkins home ───────────────────────────────────────────
resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = var.availability_zone
  size              = 50  # GB — stores jobs, builds, workspace
  type              = "gp3"
  encrypted         = true  # Encrypt at rest — required for banking compliance

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-home"
  })
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.jenkins_home.id
  instance_id = aws_instance.jenkins.id
}

# ── Jenkins EC2 Instance ──────────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = var.ami_id  # Amazon Linux 2023 AMI
  instance_type          = var.instance_type
  key_name               = var.ec2_key_name
  subnet_id              = var.private_subnet_id  # Jenkins lives in private subnet
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # This runs ONCE when the instance first boots.
  # It installs everything Jenkins needs.
  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    project_name   = var.project_name
    aws_region     = var.aws_region
    cluster_name   = var.cluster_name
    sonarqube_port = 9000
  }))

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-master"
    Role = "jenkins"
  })

  # Wait for user data to finish before Terraform says "done"
  provisioner "local-exec" {
    command = "echo 'Jenkins instance created. Wait ~5 mins for user_data to complete.'"
  }
}

# ── ALB for Jenkins UI (instead of direct EC2 public IP) ─────────────────
# This is the MNC way — never expose EC2 directly. Put it behind ALB.
resource "aws_lb" "jenkins" {
  name               = "${var.project_name}-jenkins-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.jenkins_alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod" ? true : false

  tags = var.tags
}

resource "aws_security_group" "jenkins_alb" {
  name        = "${var.project_name}-jenkins-alb-sg"
  description = "ALB for Jenkins UI"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "HTTPS from allowed CIDRs"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "HTTP (redirect to HTTPS)"
  }

  ingress {
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = [var.vpc_cidr]
  description = "Jenkins UI access from ALB within VPC"
}

  egress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Forward to Jenkins"
  }

  tags = var.tags
}

resource "aws_lb_target_group" "jenkins" {
  name     = "${var.project_name}-jenkins-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = var.tags
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 8080
}

resource "aws_lb_listener" "jenkins_http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

   default_action {
    type             = "forward"           # ← Change redirect to forward
    target_group_arn = aws_lb_target_group.jenkins.arn  # ← Add this line
  }
}

# HTTPS listener — forwards to Jenkins target group.
# Requires an ACM certificate. For the lab you can use HTTP only by
# commenting out this resource and changing the ALB SG to allow port 80.
# For MNC production: always use HTTPS with a valid ACM certificate.
resource "aws_lb_listener" "jenkins_https" {
  count             = var.acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}
