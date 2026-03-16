# ─────────────────────────────────────────────
# ECR MODULE
# One repository per application component.
# The same ECR is used by all 3 environments —
# images are differentiated by tag (git SHA).
# ─────────────────────────────────────────────

locals {
  repositories = ["frontend", "backend"]
}

resource "aws_ecr_repository" "app" {
  for_each = toset(local.repositories)

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"  # Once pushed, a tag cannot be overwritten — critical for traceability

  image_scanning_configuration {
    scan_on_push = true  # ECR scans for OS and package CVEs on every push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}"
  })
}

# ── Lifecycle policy — keep only the last N images ────────────────────────
# Without this, ECR fills up. We keep 30 tagged (for rollbacks) and
# remove untagged (failed builds) after 1 day.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-", "dev-", "staging-", "prod-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── ECR Repository Policy — allows EKS nodes and Jenkins to pull/push ────
resource "aws_ecr_repository_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowJenkinsPushPull"
        Effect = "Allow"
        Principal = {
          AWS = var.jenkins_role_arn
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:GetRepositoryPolicy",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
      },
      {
        Sid    = "AllowEKSNodePull"
        Effect = "Allow"
        Principal = {
          AWS = var.eks_node_role_arn
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}
