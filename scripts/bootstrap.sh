#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — Run this ONCE before any terraform commands.
#
# Creates:
#   1. S3 bucket for Terraform remote state
#   2. DynamoDB table for state file locking
#   3. EC2 key pair for Jenkins and EKS nodes
#
# Why remote state?
#   - Without it, only the person who ran terraform can destroy or modify infra
#   - S3 + DynamoDB = shared state + locking (prevents two people applying simultaneously)
#   - This is non-negotiable in any team environment
#
# Usage:
#   chmod +x scripts/bootstrap.sh
#   ./scripts/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="mnc-app-terraform-state-${AWS_ACCOUNT_ID}"
LOCK_TABLE="terraform-state-lock"
KEY_PAIR_NAME="mnc-app-keypair"

echo "=== MNC App Infrastructure Bootstrap ==="
echo "Account ID : $AWS_ACCOUNT_ID"
echo "Region     : $AWS_REGION"
echo "S3 bucket  : $STATE_BUCKET"
echo ""

# ── 1. Create S3 bucket for Terraform state ───────────────────────────────
echo "[1/4] Creating Terraform state S3 bucket..."
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    echo "  ✓ Bucket already exists: $STATE_BUCKET"
else
    aws s3api create-bucket \
        --bucket "$STATE_BUCKET" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"

    # Versioning: lets you recover a previous state file if something goes wrong
    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled

    # Encryption at rest
    aws s3api put-bucket-encryption \
        --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'

    # Block all public access — state files must NEVER be public
    aws s3api put-public-access-block \
        --bucket "$STATE_BUCKET" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    echo "  ✓ Created and secured bucket: $STATE_BUCKET"
fi

# ── 2. Create DynamoDB table for state locking ────────────────────────────
echo "[2/4] Creating DynamoDB state lock table..."
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" 2>/dev/null; then
    echo "  ✓ DynamoDB table already exists: $LOCK_TABLE"
else
    aws dynamodb create-table \
        --table-name "$LOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION"

    echo "  ✓ Created DynamoDB table: $LOCK_TABLE"
fi

# ── 3. Create EC2 key pair ────────────────────────────────────────────────
echo "[3/4] Creating EC2 key pair..."
if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$AWS_REGION" 2>/dev/null; then
    echo "  ✓ Key pair already exists: $KEY_PAIR_NAME"
else
    aws ec2 create-key-pair \
        --key-name "$KEY_PAIR_NAME" \
        --region "$AWS_REGION" \
        --query "KeyMaterial" \
        --output text > ~/.ssh/${KEY_PAIR_NAME}.pem

    chmod 400 ~/.ssh/${KEY_PAIR_NAME}.pem
    echo "  ✓ Created key pair. Private key saved to: ~/.ssh/${KEY_PAIR_NAME}.pem"
    echo "  ⚠ IMPORTANT: Back this up securely. If lost, you cannot SSH into EC2 instances."
fi

# ── 4. Update backend bucket name in terraform config ─────────────────────
echo "[4/4] Patching S3 backend bucket name in infra/main.tf..."
sed -i "s/mnc-app-terraform-state/$STATE_BUCKET/g" infra/main.tf
echo "  ✓ Updated bucket name to: $STATE_BUCKET"

echo ""
echo "═══════════════════════════════════════════"
echo "  Bootstrap complete! Next steps:"
echo "═══════════════════════════════════════════"
echo ""
echo "  1. Deploy DEV environment:"
echo "     cd infra/environments/dev"
echo "     terraform init"
echo "     terraform plan -var-file=terraform.tfvars -var='db_password=YourPass123!'"
echo "     terraform apply -var-file=terraform.tfvars -var='db_password=YourPass123!'"
echo ""
echo "  2. After dev is up, install the ALB controller on EKS:"
echo "     ../../../scripts/install-alb-controller.sh dev"
echo ""
echo "  3. Deploy staging and prod the same way (no create_ecr=true needed)"
echo ""
echo "  4. Open Jenkins at the ALB DNS from terraform output."
echo "     Get the initial password from SSM:"
echo "     aws ssm get-parameter --name /mnc-app/jenkins/initial-password --with-decryption --query Parameter.Value --output text"
echo ""
