#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# inject-secrets.sh
# Called by Jenkins in the pipeline BEFORE applying K8s manifests.
# Pulls the DB password from SSM and creates the Kubernetes Secret.
#
# This is the MNC pattern for secret management without a secrets vault:
#   SSM Parameter Store (SecureString) → Kubernetes Secret → Pod env var
#
# Usage: ./scripts/inject-secrets.sh <environment>
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

ENVIRONMENT="${1}"
PROJECT_NAME="mnc-app"
AWS_REGION="ap-south-1"

echo "=== Injecting secrets for $ENVIRONMENT ==="

# Pull DB password from SSM (stored there by Terraform)
DB_PASSWORD=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/db/password" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$AWS_REGION")

# Create/update the Kubernetes secret
# --dry-run=client -o yaml | kubectl apply -f - is the idempotent way:
# it works whether the secret exists or not (create OR update)
kubectl create secret generic app-db-secret \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --namespace="$ENVIRONMENT" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Secret 'app-db-secret' updated in namespace '$ENVIRONMENT'"

# Zero out the variable immediately — don't leave passwords in bash memory
unset DB_PASSWORD
