#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# install-alb-controller.sh
#
# Installs the AWS Load Balancer Controller on EKS.
# This is required for the Ingress resources to create AWS ALBs.
# Without this, kubectl apply -f ingress.yaml does nothing.
#
# Run once per EKS cluster after terraform apply.
#
# Usage: ./scripts/install-alb-controller.sh <environment>
# Example: ./scripts/install-alb-controller.sh dev
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

ENVIRONMENT="${1:-dev}"
PROJECT_NAME="mnc-app"
AWS_REGION="ap-south-1"
CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Installing AWS Load Balancer Controller ==="
echo "Cluster: $CLUSTER_NAME"
echo "Account: $AWS_ACCOUNT_ID"
echo ""

# ── Step 1: Update kubeconfig ─────────────────────────────────────────────
echo "[1/5] Updating kubeconfig..."
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

kubectl config current-context
echo ""

# ── Step 2: Create IAM policy for the ALB controller ─────────────────────
echo "[2/5] Creating IAM policy for ALB controller..."
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" 2>/dev/null; then
    echo "  ✓ IAM policy already exists"
else
    curl -s -o /tmp/alb-iam-policy.json \
        https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file:///tmp/alb-iam-policy.json

    echo "  ✓ IAM policy created"
fi

# ── Step 3: Create ServiceAccount with IRSA ──────────────────────────────
# IRSA = IAM Roles for Service Accounts
# The ALB controller pod gets AWS permissions via this SA — no static keys
echo "[3/5] Creating ServiceAccount with IRSA..."

OIDC_URL=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query "cluster.identity.oidc.issuer" \
    --output text | sed 's|https://||')

TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${OIDC_URL}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
                "${OIDC_URL}:aud": "sts.amazonaws.com"
            }
        }
    }]
}
EOF
)

ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-alb-controller-role"

if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "  ✓ IAM role already exists"
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY"

    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

    echo "  ✓ IAM role created and policy attached"
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

# ── Step 4: Install via Helm ──────────────────────────────────────────────
echo "[4/5] Installing ALB controller via Helm..."

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN" \
    --set region="$AWS_REGION" \
    --set vpcId=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query "cluster.resourcesVpcConfig.vpcId" \
        --output text) \
    --wait

echo "  ✓ ALB controller installed"

# ── Step 5: Verify ────────────────────────────────────────────────────────
echo "[5/5] Verifying deployment..."
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "✅ AWS Load Balancer Controller installed successfully!"
echo "   Ingress resources will now create real AWS ALBs."
echo ""
echo "Next: Apply K8s manifests for $ENVIRONMENT environment:"
echo "  kubectl apply -f k8s/$ENVIRONMENT/"
