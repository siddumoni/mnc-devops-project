#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# rollback.sh — Emergency rollback to previous deployment
#
# In an MNC, this is one of the most important operational scripts.
# When prod breaks, you need to roll back fast — not spend time figuring
# out kubectl commands under pressure.
#
# Usage: ./scripts/rollback.sh <environment> [revision]
# Example:
#   ./scripts/rollback.sh prod          # rolls back to previous version
#   ./scripts/rollback.sh prod 3        # rolls back to revision 3
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

ENVIRONMENT="${1}"
REVISION="${2:-}"  # Optional: specific revision number
PROJECT_NAME="mnc-app"
AWS_REGION="ap-south-1"
CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-cluster"

echo "⚠️  ROLLBACK INITIATED"
echo "Environment : $ENVIRONMENT"
echo "Cluster     : $CLUSTER_NAME"
echo ""

# Safety check for prod
if [[ "$ENVIRONMENT" == "prod" ]]; then
    echo "⚠️  WARNING: You are rolling back PRODUCTION."
    echo "   Press Ctrl+C within 10 seconds to abort..."
    sleep 10
fi

# Update kubeconfig
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

echo "=== Current state BEFORE rollback ==="
kubectl get pods -n "$ENVIRONMENT"
kubectl rollout history deployment/backend  -n "$ENVIRONMENT"
kubectl rollout history deployment/frontend -n "$ENVIRONMENT"
echo ""

# Perform rollback
if [[ -n "$REVISION" ]]; then
    echo "=== Rolling back to revision $REVISION ==="
    kubectl rollout undo deployment/backend  -n "$ENVIRONMENT" --to-revision="$REVISION"
    kubectl rollout undo deployment/frontend -n "$ENVIRONMENT" --to-revision="$REVISION"
else
    echo "=== Rolling back to PREVIOUS version ==="
    kubectl rollout undo deployment/backend  -n "$ENVIRONMENT"
    kubectl rollout undo deployment/frontend -n "$ENVIRONMENT"
fi

# Wait for rollback to complete
echo ""
echo "=== Waiting for rollback to complete ==="
kubectl rollout status deployment/backend  -n "$ENVIRONMENT" --timeout=300s
kubectl rollout status deployment/frontend -n "$ENVIRONMENT" --timeout=300s

echo ""
echo "=== State AFTER rollback ==="
kubectl get pods -n "$ENVIRONMENT"
kubectl get pods -n "$ENVIRONMENT" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

echo ""
echo "✅ Rollback complete for $ENVIRONMENT"
echo "   Monitor with: kubectl get pods -n $ENVIRONMENT -w"
