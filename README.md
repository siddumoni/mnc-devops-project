# MNC App — DevOps Infrastructure Setup Guide (Windows 11)

A production-grade 3-tier Java application deployed on AWS using Terraform, Jenkins, ECR, and EKS.
This guide is written entirely for **Windows 11 using PowerShell**. Every command here runs natively
on Windows — no WSL required (WSL2 is mentioned only as an optional shortcut where it genuinely helps).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites — Install All Tools](#2-prerequisites--install-all-tools)
3. [Repository Structure](#3-repository-structure)
4. [Step 1 — AWS Account Preparation](#step-1--aws-account-preparation)
5. [Step 2 — Configure Your Local Machine](#step-2--configure-your-local-machine)
6. [Step 3 — Clone and Personalise the Repo](#step-3--clone-and-personalise-the-repo)
7. [Step 4 — Bootstrap Remote State](#step-4--bootstrap-remote-state)
8. [Step 5 — Deploy Dev Infrastructure](#step-5--deploy-dev-infrastructure)
9. [Step 6 — Install the ALB Controller](#step-6--install-the-alb-controller)
10. [Step 7 — Deploy Kubernetes Manifests](#step-7--deploy-kubernetes-manifests)
11. [Step 8 — Configure Jenkins](#step-8--configure-jenkins)
12. [Step 9 — Run Your First Pipeline](#step-9--run-your-first-pipeline)
13. [Step 10 — Deploy Staging and Prod](#step-10--deploy-staging-and-prod)
14. [Day-to-Day Operations](#day-to-day-operations)
15. [Troubleshooting](#troubleshooting)
16. [Estimated AWS Cost](#estimated-aws-cost)
17. [Quick Reference](#quick-reference--most-used-commands)

---

## 1. Architecture Overview

```
GitHub (source) → Jenkins EC2 (CI/CD) → ECR (image registry) → EKS (runtime)
                                    ↓
                         SonarQube (quality gate)
                                    ↓
                   dev ns → staging ns → prod ns  (same EKS cluster)
                      ↓           ↓           ↓
                   RDS-dev   RDS-staging   RDS-prod
```

**What lives where:**

| Component        | Location                        | Why                                             |
|------------------|---------------------------------|-------------------------------------------------|
| Jenkins master   | EC2 in private subnet           | Full control, no SaaS dependency                |
| SonarQube        | Docker on Jenkins EC2 port 9000 | Co-located to avoid cross-VPC latency           |
| ECR repositories | Shared across all 3 envs        | Same image promoted — never rebuilt per env     |
| EKS cluster      | Private node groups             | Workers never exposed directly to internet      |
| RDS MySQL        | Private subnets, one per env    | Separate DB per env prevents data contamination |
| ALB              | Public subnets                  | Only internet-facing component                  |

**Branch → Environment mapping:**

| Git branch    | Deploys to | Approval required            |
|---------------|------------|------------------------------|
| `feature/*`   | (none)     | Build + test only            |
| `develop`     | dev        | Automatic                    |
| `release/*`   | staging    | 1 approval (tech lead)       |
| `main`        | prod       | 2 approvals (lead + DevOps)  |

---

## 2. Prerequisites — Install All Tools

Open **PowerShell as Administrator** for all installation steps.
Right-click the Start button → **Terminal (Admin)** or **Windows PowerShell (Admin)**.

### 2.1 Enable script execution (one-time Windows setting)

By default Windows blocks PowerShell scripts. Run this once:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
# Type Y and press Enter when prompted
```

### 2.2 Verify winget is available

winget comes pre-installed on Windows 11:

```powershell
winget --version
# Expected: v1.x.x
```

If not installed, open the Microsoft Store and search for **App Installer**.

### 2.3 Install AWS CLI v2

```powershell
winget install Amazon.AWSCLI
```

**Close and reopen PowerShell**, then verify:

```powershell
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x Windows/11
```

### 2.4 Install Terraform

```powershell
winget install Hashicorp.Terraform
```

**Close and reopen PowerShell**, then verify:

```powershell
terraform version
# Expected: Terraform v1.6.x
```

### 2.5 Install kubectl

```powershell
winget install Kubernetes.kubectl
```

Verify:

```powershell
kubectl version --client
# Expected: Client Version: v1.29.x
```

### 2.6 Install Helm

```powershell
winget install Helm.Helm
```

Verify:

```powershell
helm version
# Expected: version.BuildInfo{Version:"v3.x.x", ...}
```

### 2.7 Install Git

```powershell
winget install Git.Git
```

**Close and reopen PowerShell**, then verify:

```powershell
git --version
# Expected: git version 2.x.x.windows.x
```

### 2.8 Verify all tools are on PATH

Close every PowerShell window and open a fresh one. Run this block:

```powershell
@("aws", "terraform", "kubectl", "helm", "git") | ForEach-Object {
    $cmd = $_
    try {
        $v = & $cmd --version 2>&1 | Select-Object -First 1
        Write-Host "OK  $cmd : $v" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $cmd : NOT FOUND - close and reopen PowerShell" -ForegroundColor Red
    }
}
```

All five should be green before continuing. If any are red, close and reopen PowerShell — PATH changes require a new shell session.

---

## 3. Repository Structure

```
mnc-devops-project\
│
├── infra\                          Terraform infrastructure code
│   ├── main.tf                     Root module — wires everything together
│   ├── variables.tf                All input variable declarations
│   ├── outputs.tf                  Values printed after terraform apply
│   ├── modules\
│   │   ├── vpc\                    VPC, subnets, NAT gateways, flow logs
│   │   ├── eks\                    EKS cluster, node groups, OIDC, add-ons
│   │   ├── ecr\                    Private Docker registries
│   │   ├── ec2-jenkins\            Jenkins EC2, ALB, IAM role, security groups
│   │   └── rds\                    MySQL RDS per environment
│   └── environments\
│       ├── dev\terraform.tfvars    Dev values: SPOT nodes, micro RDS, 1 replica
│       ├── staging\terraform.tfvars
│       └── prod\terraform.tfvars   Prod values: ON_DEMAND, Multi-AZ, 3 replicas
│
├── app\
│   ├── backend\                    Spring Boot REST API (Java 17, Maven)
│   │   ├── Dockerfile              Multi-stage: builder stage + slim runtime stage
│   │   ├── pom.xml                 JPA, MySQL, Actuator, JaCoCo, SonarQube plugin
│   │   └── src\
│   │       ├── main\java\com\mnc\app\
│   │       │   ├── controller\     REST endpoints (/api/products)
│   │       │   ├── service\        Business logic
│   │       │   ├── repository\     JPA database access
│   │       │   └── model\          Product entity
│   │       └── test\               Unit tests (Mockito + H2 in-memory DB)
│   ├── frontend\                   React app, served by Nginx
│   │   ├── Dockerfile              Multi-stage: Node builder + Nginx runtime
│   │   └── nginx.conf              SPA routing, gzip, security headers
│   └── database\schema.sql         MySQL schema + seed data
│
├── k8s\                            Kubernetes manifests — one folder per environment
│   ├── dev\                        1 replica, DEBUG logs, smallest resources
│   ├── staging\                    2 replicas, preferred anti-affinity
│   └── prod\                       3 replicas + HPA + PodDisruptionBudget
│
├── jenkins\
│   └── Jenkinsfile                 CI/CD pipeline: build → scan → push → approve → deploy
│
└── scripts\                        Operational scripts (run from your Windows machine)
    ├── bootstrap.sh                Bash version (see Step 4 for PowerShell equivalent)
    ├── install-alb-controller.sh   Bash version (see Step 6 for PowerShell equivalent)
    ├── inject-secrets.sh           Bash version (see Step 7 for PowerShell equivalent)
    └── rollback.sh                 Bash version (see Day-to-Day for PowerShell equivalent)
```

> **Note on the .sh scripts:** The `scripts\` folder contains bash versions for Linux/Mac colleagues.
> This guide gives you the PowerShell equivalent of every script inline so you do not need bash at all.

---

## Step 1 — AWS Account Preparation

### 1.1 Create a dedicated IAM user for Terraform

> Never use your root account for automation. Root has no audit trail and no permission boundary.

1. Go to **AWS Console → IAM → Users → Create user**
2. Username: `terraform-admin`
3. Leave "Provide user access to AWS Management Console" **unchecked** (CLI only)
4. Permissions → **Attach policies directly** → tick `AdministratorAccess`
5. Create user → click on the user → **Security credentials** tab
6. **Access keys → Create access key → Command Line Interface (CLI)**
7. Download the CSV file — you need both the Access Key ID and Secret Access Key

### 1.2 Configure AWS CLI with those credentials

Open PowerShell (regular, not Admin):

```powershell
aws configure
```

Fill in each prompt:
```
AWS Access Key ID [None]:     PASTE_YOUR_ACCESS_KEY_ID
AWS Secret Access Key [None]: PASTE_YOUR_SECRET_ACCESS_KEY
Default region name [None]:   ap-south-1
Default output format [None]: json
```

Verify it works:

```powershell
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/terraform-admin"
}
```

Save your **Account ID** — the 12-digit number. You will use it in Step 3.

### 1.3 Store account ID as a variable for use in this session

```powershell
$AWS_ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
Write-Host "Account ID: $AWS_ACCOUNT_ID"
```

> **Tip:** PowerShell variables (`$VAR`) only live for the current session. If you close and reopen PowerShell you will need to re-run `$AWS_ACCOUNT_ID = (aws sts ...)` before commands that use it.

---

## Step 2 — Configure Your Local Machine

### 2.1 Find your public IP address

```powershell
$MY_IP = (Invoke-WebRequest -Uri "https://ifconfig.me" -UseBasicParsing).Content.Trim()
Write-Host "Your public IP: $MY_IP"
```

This IP will be used to restrict access to the Jenkins UI to your machine only. If you work from multiple locations, you can add multiple IPs or use a VPN IP.

### 2.2 Get the latest Amazon Linux 2023 AMI ID for ap-south-1

```powershell
$AMI_ID = aws ec2 describe-images `
    --owners amazon `
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" `
              "Name=state,Values=available" `
    --query "sort_by(Images, &CreationDate)[-1].ImageId" `
    --output text `
    --region ap-south-1

Write-Host "Latest AMI ID: $AMI_ID"
```

### 2.3 Create the SSH key directory if it doesn't exist

```powershell
$sshDir = "$env:USERPROFILE\.ssh"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
    Write-Host "Created: $sshDir"
} else {
    Write-Host "Already exists: $sshDir"
}
```

---

## Step 3 — Clone and Personalise the Repo

### 3.1 Create a working directory and clone

```powershell
New-Item -ItemType Directory -Path "C:\Projects" -Force | Out-Null
Set-Location "C:\Projects"

git clone https://github.com/YOUR_USERNAME/mnc-devops-project.git
Set-Location mnc-devops-project
```

### 3.2 Update all three tfvars files in one shot

Paste this entire block into PowerShell. It auto-detects your account ID, IP, and AMI, then updates all three environment files:

```powershell
# Auto-detect values
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$MY_IP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip").Trim()
$AMI_ID     = aws ec2 describe-images `
                  --owners amazon `
                  --filters "Name=name,Values=al2023-ami-2023*-x86_64" `
                            "Name=state,Values=available" `
                  --query "sort_by(Images, &CreationDate)[-1].ImageId" `
                  --output text `
                  --region ap-south-1

Write-Host ""
Write-Host "Values detected:"
Write-Host "  Account ID : $ACCOUNT_ID"
Write-Host "  My IP      : $MY_IP"
Write-Host "  AMI ID     : $AMI_ID"
Write-Host ""

# Update all three tfvars files
$files = @(
    "infra\environments\dev\terraform.tfvars",
    "infra\environments\staging\terraform.tfvars",
    "infra\environments\prod\terraform.tfvars"
)

foreach ($file in $files) {
    $content = Get-Content $file -Raw
    $content = $content -replace "123456789012",           $ACCOUNT_ID
    $content = $content -replace "YOUR_OFFICE_IP",         $MY_IP
    $content = $content -replace "ami-0f58b397bc5c1f2e8",  $AMI_ID
    Set-Content -Path $file -Value $content -NoNewline
    Write-Host "  Updated: $file" -ForegroundColor Green
}
```

### 3.3 Verify the changes look right

```powershell
Select-String `
    -Path "infra\environments\dev\terraform.tfvars" `
    -Pattern "aws_account_id|allowed_cidr|ami_id"
```

You should see your real account ID, your real IP, and the real AMI ID — not placeholders.

### 3.3a Understanding the Terraform module structure (important — read before running)

Before running `terraform init`, understand how this project is organised so you are not confused when you look at the files:

```
environments/dev/main.tf      ← you run terraform from HERE
  └── calls source = "../../"
        └── infra/main.tf     ← root module (NO backend block — modules cannot have backends)
              ├── modules/vpc/
              ├── modules/eks/
              ├── modules/ec2-jenkins/
              ├── modules/ecr/
              └── modules/rds/
```

The `terraform {}` block with the `backend "s3" {}` section lives **only** in `environments/dev/main.tf`, `environments/staging/main.tf`, and `environments/prod/main.tf`. The root `infra/main.tf` intentionally has **no** `terraform {}` block because Terraform does not allow backend configuration inside a called module — only inside the root configuration (the directory where you actually run `terraform init`).

### 3.4 Push the changes to GitHub

```powershell
git add .
git commit -m "config: set account ID, IP, and AMI for all environments"
git push origin main

# Create the develop branch (pipeline needs it)
git checkout -b develop
git push -u origin develop
git checkout main
```

---

## Step 4 — Bootstrap Remote State

Run this **once**, before any `terraform` command. It creates the S3 bucket and DynamoDB table that Terraform uses to store and share state files.

```powershell
# ── Variables ─────────────────────────────────────────────────────────────
$AWS_REGION    = "ap-south-1"
$ACCOUNT_ID    = (aws sts get-caller-identity --query Account --output text)
$STATE_BUCKET  = "mnc-app-terraform-state-$ACCOUNT_ID"
$LOCK_TABLE    = "terraform-state-lock"
$KEY_PAIR_NAME = "mnc-app-keypair"

Write-Host "=== Bootstrap ===" -ForegroundColor Cyan
Write-Host "  Bucket : $STATE_BUCKET"
Write-Host "  Table  : $LOCK_TABLE"
Write-Host ""

# ── [1/4] S3 Bucket ───────────────────────────────────────────────────────
Write-Host "[1/4] S3 state bucket..." -ForegroundColor Yellow
$exists = aws s3api head-bucket --bucket $STATE_BUCKET 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Already exists" -ForegroundColor Green
} else {
    aws s3api create-bucket `
        --bucket $STATE_BUCKET `
        --region $AWS_REGION `
        --create-bucket-configuration LocationConstraint=$AWS_REGION | Out-Null

    aws s3api put-bucket-versioning `
        --bucket $STATE_BUCKET `
        --versioning-configuration Status=Enabled | Out-Null

    # Encryption at rest
    $encConfig = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-bucket-encryption `
        --bucket $STATE_BUCKET `
        --server-side-encryption-configuration $encConfig | Out-Null

    # Block all public access — state files must NEVER be public
    aws s3api put-public-access-block `
        --bucket $STATE_BUCKET `
        --public-access-block-configuration `
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null

    Write-Host "  Created and secured" -ForegroundColor Green
}

# ── [2/4] DynamoDB Lock Table ─────────────────────────────────────────────
Write-Host "[2/4] DynamoDB lock table..." -ForegroundColor Yellow
$tableCheck = aws dynamodb describe-table --table-name $LOCK_TABLE --region $AWS_REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Already exists" -ForegroundColor Green
} else {
    aws dynamodb create-table `
        --table-name $LOCK_TABLE `
        --attribute-definitions AttributeName=LockID,AttributeType=S `
        --key-schema AttributeName=LockID,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $AWS_REGION | Out-Null
    Write-Host "  Created" -ForegroundColor Green
}

# ── [3/4] EC2 Key Pair ────────────────────────────────────────────────────
Write-Host "[3/4] EC2 key pair..." -ForegroundColor Yellow
$keyCheck = aws ec2 describe-key-pairs --key-names $KEY_PAIR_NAME --region $AWS_REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Already exists" -ForegroundColor Green
} else {
    $keyMaterial = aws ec2 create-key-pair `
        --key-name $KEY_PAIR_NAME `
        --region $AWS_REGION `
        --query "KeyMaterial" `
        --output text

    $keyPath = "$env:USERPROFILE\.ssh\$KEY_PAIR_NAME.pem"
    $keyMaterial | Set-Content -Path $keyPath -NoNewline

    # Restrict permissions (Windows equivalent of chmod 400)
    $acl = Get-Acl $keyPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, "Read", "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl $keyPath $acl

    Write-Host "  Saved to: $keyPath" -ForegroundColor Green
    Write-Host "  IMPORTANT: Back this up - you need it to SSH into EC2" -ForegroundColor Yellow
}

# ── [4/4] Patch bucket name into all environment main.tf files ────────────
# The bucket name lives in environments/dev/main.tf, staging/main.tf, and
# prod/main.tf — NOT in infra/main.tf (the root module has no backend block).
Write-Host "[4/4] Patching bucket name into environment main.tf files..." -ForegroundColor Yellow

$envFiles = @(
    "infra\environments\dev\main.tf",
    "infra\environments\staging\main.tf",
    "infra\environments\prod\main.tf"
)

foreach ($file in $envFiles) {
    $content = Get-Content $file -Raw
    $content = $content -replace 'bucket\s*=\s*"mnc-app-terraform-state"', "bucket = `"$STATE_BUCKET`""
    Set-Content -Path $file -Value $content -NoNewline
    Write-Host "  Updated: $file" -ForegroundColor Green
}

Write-Host ""
Write-Host "Bootstrap complete. Proceed to Step 5." -ForegroundColor Cyan
```

Expected: all four steps show green. If Step 1 shows "Access Denied", your IAM user is missing S3 permissions — re-check Step 1.1.

---

## Step 5 — Deploy Dev Infrastructure

This provisions VPC, EKS cluster, Jenkins EC2, ECR repos, and RDS. Takes about **15–20 minutes**.

### 5.1 Navigate to the dev environment

```powershell
Set-Location "C:\Projects\mnc-devops-project\infra\environments\dev"
```

### 5.2 Initialise Terraform

```powershell
terraform init
```

Last few lines of expected output:
```
Initializing the backend...
Successfully configured the backend "s3"!
Terraform has been successfully initialized!
```

> **"Error: Failed to get existing workspaces"** — the S3 bucket doesn't exist. Go back and run Step 4.

### 5.3 Preview the plan

```powershell
terraform plan `
    -var-file="terraform.tfvars" `
    -var="db_password=DevPass123!" `
    -out="dev.tfplan"
```

> **Note on the backtick `` ` ``:** In PowerShell this is the line-continuation character (same as `\` in bash). The command above is one long command split across four lines.

Scan the output — you should see **60–70 resources** being added. Key ones to confirm:
```
+ aws_vpc.main
+ aws_eks_cluster.main
+ aws_instance.jenkins
+ aws_ecr_repository.app["frontend"]
+ aws_ecr_repository.app["backend"]
+ aws_db_instance.main
```

### 5.4 Apply

```powershell
terraform apply "dev.tfplan"
```

Watch the output — EKS takes ~10 minutes. When complete:
```
Apply complete! Resources: 68 added, 0 changed, 0 destroyed.
```

### 5.5 Save the outputs

```powershell
terraform output
```

You will see something like:
```
cluster_name    = "mnc-app-dev-cluster"
jenkins_alb_dns = "mnc-app-jenkins-alb-12345.ap-south-1.elb.amazonaws.com"
db_endpoint     = "mnc-app-dev-mysql.abc123.ap-south-1.rds.amazonaws.com:3306"
ecr_repository_urls = {
  "backend"  = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/mnc-app/backend"
  "frontend" = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/mnc-app/frontend"
}
```

Paste this into Notepad — you will reference it throughout the remaining steps.

### 5.6 Update the dev ConfigMap with the real RDS endpoint

```powershell
# Go back to project root
Set-Location "C:\Projects\mnc-devops-project"

# Get the RDS hostname (strip the :3306 port suffix)
$RDS_HOST = (terraform -chdir="infra\environments\dev" output -raw db_endpoint) -replace ":3306", ""

# Patch configmap.yaml
$cm = Get-Content "k8s\dev\configmap.yaml" -Raw
$cm = $cm -replace "mnc-app-dev-mysql\.xxxxxxxxxx\.ap-south-1\.rds\.amazonaws\.com", $RDS_HOST
Set-Content -Path "k8s\dev\configmap.yaml" -Value $cm -NoNewline

Write-Host "ConfigMap updated with: $RDS_HOST" -ForegroundColor Green
```

### 5.7 Connect kubectl to the EKS cluster

```powershell
aws eks update-kubeconfig `
    --region ap-south-1 `
    --name mnc-app-dev-cluster

kubectl get nodes
```

Expected (nodes may take 2–3 minutes to reach Ready after Terraform completes):
```
NAME                                          STATUS   ROLES    AGE
ip-10-10-10-xx.ap-south-1.compute.internal   Ready    <none>   2m
ip-10-10-11-xx.ap-south-1.compute.internal   Ready    <none>   2m
```

---

## Step 6 — Install the ALB Controller

Without this, applying `ingress.yaml` does nothing. This controller watches Ingress resources and creates real AWS ALBs.

```powershell
# Fix the file:// path format for Windows
# $env:TEMP on Windows gives C:\Users\...\AppData\Local\Temp
# AWS CLI on Windows needs file:// with the drive letter directly — no leading slash

Set-Location "C:\Projects\mnc-devops-project"

$AWS_REGION   = "ap-south-1"
$ACCOUNT_ID   = (aws sts get-caller-identity --query Account --output text)
$CLUSTER_NAME = "mnc-app-dev-cluster"
$POLICY_NAME  = "AWSLoadBalancerControllerIAMPolicy"
$ROLE_NAME    = "mnc-app-dev-alb-controller-role"

# ── [1/4] IAM Policy ──────────────────────────────────────────────────────
Write-Host "[1/4] Creating IAM policy..." -ForegroundColor Yellow

$policyCheck = aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/$POLICY_NAME" 2>&1
if ($LASTEXITCODE -ne 0) {
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json" `
        -OutFile "C:\Temp\alb-policy.json" `
        -UseBasicParsing

    # Windows fix: use file://C:\path format (no triple slash)
    aws iam create-policy `
        --policy-name $POLICY_NAME `
        --policy-document "file://C:\Temp\alb-policy.json"

    Write-Host "  Created" -ForegroundColor Green
} else {
    Write-Host "  Already exists" -ForegroundColor Green
}

# ── [2/4] IRSA Trust Role ─────────────────────────────────────────────────
Write-Host "[2/4] IRSA role..." -ForegroundColor Yellow

$OIDC = (aws eks describe-cluster `
    --name $CLUSTER_NAME `
    --region $AWS_REGION `
    --query "cluster.identity.oidc.issuer" `
    --output text) -replace "https://", ""

$trust = @"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "${OIDC}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
"@

# Windows fix: write to C:\Temp and use file://C:\path format
[System.IO.File]::WriteAllText("C:\Temp\alb-trust.json", $trust)

$roleCheck = aws iam get-role --role-name $ROLE_NAME 2>&1
if ($LASTEXITCODE -ne 0) {
    aws iam create-role `
        --role-name $ROLE_NAME `
        --assume-role-policy-document "file://C:\Temp\alb-trust.json"

    aws iam attach-role-policy `
        --role-name $ROLE_NAME `
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/$POLICY_NAME"

    Write-Host "  Created" -ForegroundColor Green
} else {
    Write-Host "  Already exists" -ForegroundColor Green
}

# ── [3/4] Get VPC ID ──────────────────────────────────────────────────────
$VPC_ID = aws eks describe-cluster `
    --name $CLUSTER_NAME `
    --region $AWS_REGION `
    --query "cluster.resourcesVpcConfig.vpcId" `
    --output text

$ROLE_ARN = "arn:aws:iam::${ACCOUNT_ID}:role/$ROLE_NAME"

# ── [4/4] Helm install ────────────────────────────────────────────────────
Write-Host "[4/4] Helm install..." -ForegroundColor Yellow

helm repo add eks https://aws.github.io/eks-charts 2>$null
helm repo update | Out-Null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
    --namespace kube-system `
    --set clusterName=$CLUSTER_NAME `
    --set serviceAccount.create=true `
    --set serviceAccount.name=aws-load-balancer-controller `
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN" `
    --set region=$AWS_REGION `
    --set vpcId=$VPC_ID `
    --wait

Write-Host ""
kubectl get deployment aws-load-balancer-controller -n kube-system
Write-Host "ALB Controller ready." -ForegroundColor Green

# Cleanup
Remove-Item "C:\Temp\alb-policy.json" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\alb-trust.json"  -Force -ErrorAction SilentlyContinue

---

## Step 7 — Deploy Kubernetes Manifests

### 7.1 Inject the database secret into Kubernetes

This pulls the DB password from AWS SSM (where Terraform stored it) and creates a Kubernetes Secret — without writing the password to any file on disk.

```powershell
$ENV_NAME = "dev"
$PROJECT  = "mnc-app"
$REGION   = "ap-south-1"

$DB_PASS = aws ssm get-parameter `
    --name "/$PROJECT/$ENV_NAME/db/password" `
    --with-decryption `
    --query "Parameter.Value" `
    --output text `
    --region $REGION

kubectl create secret generic app-db-secret `
    "--from-literal=DB_PASSWORD=$DB_PASS" `
    --namespace=$ENV_NAME `
    --dry-run=client -o yaml | kubectl apply -f -

Remove-Variable DB_PASS   # Clear from memory immediately

Write-Host "Secret injected into namespace '$ENV_NAME'" -ForegroundColor Green
```

### 7.2 Apply the database schema

The Jenkins EC2 is in a private subnet — you reach it using **AWS Systems Manager Session Manager** (no open ports, no SSH key needed from your laptop).

**Install the SSM Session Manager plugin for Windows (one-time):**

```powershell
# Download installer
Invoke-WebRequest `
    -Uri "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe" `
    -OutFile "$env:TEMP\SSMPlugin.exe" `
    -UseBasicParsing

# Run installer (requires Admin PowerShell)
Start-Process "$env:TEMP\SSMPlugin.exe" -Wait -Verb RunAs

Write-Host "SSM plugin installed. Close and reopen PowerShell." -ForegroundColor Green
```

**After reopening PowerShell — upload the schema and apply it:**

```powershell
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$BUCKET     = "mnc-app-terraform-state-$ACCOUNT_ID"
$REGION     = "ap-south-1"

# Upload schema to S3 so Jenkins can download it
aws s3 cp "app\database\schema.sql" "s3://$BUCKET/tmp/schema.sql" --region $REGION

# Get Jenkins instance ID
$JENKINS_ID = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mnc-app-jenkins-master" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text --region $REGION

# Get RDS endpoint
$RDS_HOST = (terraform -chdir="infra\environments\dev" output -raw db_endpoint) -replace ":3306", ""

# Prompt for DB password (secure - doesn't show on screen)
$securePass = Read-Host "Enter DB password used in terraform apply" -AsSecureString
$DB_PASS    = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))

# Run schema via SSM Run Command
$cmdId = aws ssm send-command `
    --instance-ids $JENKINS_ID `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[
        'aws s3 cp s3://$BUCKET/tmp/schema.sql /tmp/schema.sql --region $REGION',
        'mysql -h $RDS_HOST -u appuser -p$DB_PASS < /tmp/schema.sql && echo Schema OK'
    ]" `
    --region $REGION `
    --query "Command.CommandId" `
    --output text

Remove-Variable DB_PASS

Write-Host "Schema command sent. Command ID: $cmdId"
Write-Host "Check result: AWS Console → Systems Manager → Run Command → $cmdId"
```

### 7.3 Apply all manifests for dev

```powershell
Set-Location "C:\Projects\mnc-devops-project"
kubectl apply -f k8s\dev\
```

Expected:
```
namespace/dev configured
configmap/app-config configured
deployment.apps/backend created
deployment.apps/frontend created
service/backend-service created
service/frontend-service created
ingress.networking.k8s.io/app-ingress created
```

### 7.4 Watch pods come up

```powershell
kubectl get pods -n dev -w
# Press Ctrl+C when all pods show 1/1 Running
```

> **Pod in ContainerCreating?** `kubectl describe pod <name> -n dev` — look at Events section.
>
> **Pod in CrashLoopBackOff?** `kubectl logs <name> -n dev` — look at the Java exception.

### 7.5 Get the ALB address and test the app

```powershell
# Wait 2-3 minutes for the ALB to be provisioned
kubectl get ingress app-ingress -n dev

# Once ADDRESS column shows a hostname, test the API
$ALB = kubectl get ingress app-ingress -n dev `
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

Write-Host "App URL: http://$ALB"
Write-Host "API test:"
(Invoke-WebRequest -Uri "http://$ALB/api/products" -UseBasicParsing).Content
```

---

## Step 8 — Configure Jenkins

### 8.1 Open Jenkins

```powershell
$JENKINS_DNS = terraform -chdir="infra\environments\dev" output -raw jenkins_alb_dns
Write-Host "Open in browser: http://$JENKINS_DNS"
```

Open that URL in Chrome or Edge.

> **HTTP vs HTTPS:** For this lab the Jenkins ALB runs on HTTP (port 80) because `acm_certificate_arn` defaults to `""` in `terraform.tfvars`. The HTTP listener still redirects to port 443 in the config, but since no HTTPS listener is provisioned, just use `http://`. For a real MNC production setup, request a free ACM certificate in the AWS Console (`Certificate Manager → Request → public certificate`), then add `acm_certificate_arn = "arn:aws:acm:ap-south-1:ACCOUNT:certificate/UUID"` to your `terraform.tfvars` file and re-run `terraform apply` — the HTTPS listener will be created automatically.

### 8.2 Get the initial admin password

```powershell
aws ssm get-parameter `
    --name "/mnc-app/jenkins/initial-password" `
    --with-decryption `
    --query "Parameter.Value" `
    --output text `
    --region ap-south-1
```

Paste this into the Jenkins unlock screen.

> **Parameter not found yet?** The EC2 user data script takes 5–8 minutes after instance creation. Wait and retry. To check progress, go to **AWS Console → Systems Manager → Run Command** or:
> ```powershell
> aws ssm send-command `
>     --instance-ids $JENKINS_ID `
>     --document-name "AWS-RunShellScript" `
>     --parameters "commands=['tail -30 /var/log/jenkins-setup.log']" `
>     --region ap-south-1 | Out-Null
> # Check output in AWS Console → Systems Manager → Run Command → latest command
> ```

### 8.3 Install suggested plugins + additional plugins

On the **Customize Jenkins** screen → **Install suggested plugins** (takes ~5 minutes).

After restart, go to **Manage Jenkins → Plugins → Available plugins** and install each of these:

| Search for this | Why |
|---|---|
| `Pipeline` | Jenkinsfile support |
| `Docker Pipeline` | docker.build / docker.push steps |
| `SonarQube Scanner` | withSonarQubeEnv + waitForQualityGate |
| `GitHub` | Webhook triggers |
| `Timestamper` | Timestamps on log lines |
| `AnsiColor` | Coloured console output |
| `JaCoCo` | Code coverage reports |

After installing → **Restart Jenkins** (or open `http://<JENKINS_DNS>/restart`).

### 8.4 Create a GitHub Personal Access Token

1. Open `https://github.com/settings/tokens`
2. **Generate new token (classic)**
3. Name: `jenkins-mnc-app`
4. Scopes: tick `repo` (all sub-items) and `admin:repo_hook`
5. **Generate token** — copy it immediately (shown only once)

### 8.5 Add credentials in Jenkins

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

**GitHub credential:**

| Field | Value |
|---|---|
| Kind | `Username with password` |
| Username | your GitHub username |
| Password | the GitHub token from 8.4 |
| ID | `github-credentials` |

**SonarQube token** (add after completing Step 8.6):

| Field | Value |
|---|---|
| Kind | `Secret text` |
| Secret | token from SonarQube |
| ID | `sonarqube-token` |

### 8.6 Access SonarQube via SSM port-forwarding tunnel

SonarQube runs on port 9000 on the Jenkins EC2 private IP. You reach it by tunnelling through SSM.

**Open a second PowerShell window** and run (keep this window open the entire time you use SonarQube):

```powershell
$JENKINS_ID = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mnc-app-jenkins-master" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text --region ap-south-1

aws ssm start-session `
    --target $JENKINS_ID `
    --document-name AWS-StartPortForwardingSession `
    --parameters "portNumber=9000,localPortNumber=9000" `
    --region ap-south-1
```

Now open `http://localhost:9000` in your browser.

Login: `admin` / `admin` → change password when prompted.

Generate the Jenkins analysis token:
1. Top-right corner → click **admin** → **My Account**
2. **Security** tab → **Generate Tokens**
3. Name: `jenkins-token`, Type: **Global Analysis Token**
4. Copy the token → add it to Jenkins credentials as `sonarqube-token` (from Step 8.5)

### 8.7 Configure SonarQube server in Jenkins

**Manage Jenkins → System** → scroll to **SonarQube servers** → **Add SonarQube**:

| Field | Value |
|---|---|
| Name | `SonarQube-Server` ← must match Jenkinsfile exactly |
| Server URL | `http://localhost:9000` |
| Server auth token | select `sonarqube-token` |

Save.

### 8.8 Configure Maven and Java tools

**Manage Jenkins → Tools**:

**JDK installations → Add JDK:**
- Name: `Java-17` ← must match exactly
- Install automatically: checked, Version: Java 17

**Maven installations → Add Maven:**
- Name: `Maven-3.9` ← must match exactly
- Install automatically: checked, Version: 3.9.6

Save.

### 8.9 Create the Multibranch Pipeline job

1. Jenkins home → **New Item**
2. Name: `mnc-app-pipeline`, Type: **Multibranch Pipeline** → OK
3. **Branch Sources → Add source → GitHub**
   - Credentials: `github-credentials`
   - Repository HTTPS URL: `https://github.com/YOUR_USERNAME/mnc-devops-project`
4. **Build Configuration** → by Jenkinsfile → Script Path: `jenkins/Jenkinsfile`
5. **Scan Triggers** → Periodically if not otherwise run → 1 minute
6. Save

Jenkins immediately scans and discovers `main` and `develop` branches.

### 8.10 GitHub webhook (makes builds instant instead of polling)

In your GitHub repo: **Settings → Webhooks → Add webhook**

| Field | Value |
|---|---|
| Payload URL | `http://<JENKINS_ALB_DNS>/github-webhook/` |
| Content type | `application/json` |
| Events | Just the push event |

---

## Step 9 — Run Your First Pipeline

### 9.1 Trigger a dev build

```powershell
Set-Location "C:\Projects\mnc-devops-project"
git checkout develop

# Make a small change to trigger a build
Add-Content -Path "README.md" -Value "`n<!-- trigger: first pipeline run -->"

git add .
git commit -m "trigger: first dev pipeline run"
git push origin develop
```

In Jenkins → **mnc-app-pipeline → develop** → watch stages execute.

### 9.2 What you should see in order

```
 Checkout            - prints branch, git SHA, target environment
 Build & Unit Tests  - mvn clean install, JUnit results published
 SonarQube Analysis  - sends code to SonarQube for analysis
 Quality Gate        - waits for SonarQube pass/fail (up to 10 min)
 Docker Build & Push - builds both images, tags sha-xxxxxx, pushes to ECR
 Deploy to DEV       - kubectl apply to dev namespace, waits for rollout
 Smoke Tests         - hits /actuator/health, confirms HTTP 200
```

First run takes ~10 minutes (Maven downloads dependencies). Subsequent runs: ~4–5 minutes.

### 9.3 Test the staging approval gate

```powershell
git checkout -b release/1.0.0
git push origin release/1.0.0
```

Jenkins picks up the branch. When it pauses at **"Approval: Deploy to STAGING?"**, go to Jenkins UI and click **Deploy to Staging**.

### 9.4 Test the prod dual-approval gate

```powershell
git checkout main
git merge release/1.0.0
git push origin main
```

Jenkins pauses twice — Tech Lead approval, then DevOps Manager approval. In the lab, you click both.

---

## Step 10 — Deploy Staging and Prod

### 10.1 Staging infrastructure

```powershell
Set-Location "C:\Projects\mnc-devops-project\infra\environments\staging"
terraform init
terraform apply -var-file="terraform.tfvars" -var="db_password=StagingPass123!" -auto-approve

# Update configmap with staging RDS endpoint
Set-Location "C:\Projects\mnc-devops-project"
$S_RDS = (terraform -chdir="infra\environments\staging" output -raw db_endpoint) -replace ":3306",""
$cm    = Get-Content "k8s\staging\configmap.yaml" -Raw
$cm    = $cm -replace "mnc-app-staging-mysql\.xxxxxxxxxx\.ap-south-1\.rds\.amazonaws\.com", $S_RDS
Set-Content "k8s\staging\configmap.yaml" $cm -NoNewline

# Inject secret and apply manifests
$DB = aws ssm get-parameter --name "/mnc-app/staging/db/password" `
    --with-decryption --query "Parameter.Value" --output text --region ap-south-1
kubectl create secret generic app-db-secret "--from-literal=DB_PASSWORD=$DB" `
    --namespace=staging --dry-run=client -o yaml | kubectl apply -f -
Remove-Variable DB

kubectl apply -f k8s\staging\
kubectl get pods -n staging -w
```

### 10.2 Prod infrastructure

```powershell
Set-Location "C:\Projects\mnc-devops-project\infra\environments\prod"
terraform init
terraform apply -var-file="terraform.tfvars" -var="db_password=ProdPass456!" -auto-approve

Set-Location "C:\Projects\mnc-devops-project"
$P_RDS = (terraform -chdir="infra\environments\prod" output -raw db_endpoint) -replace ":3306",""
$cm    = Get-Content "k8s\prod\configmap.yaml" -Raw
$cm    = $cm -replace "mnc-app-prod-mysql\.xxxxxxxxxx\.ap-south-1\.rds\.amazonaws\.com", $P_RDS
Set-Content "k8s\prod\configmap.yaml" $cm -NoNewline

# Update prod ingress: replace domain + ACM cert ARN before applying
# Edit k8s\prod\services-ingress.yaml in Notepad:
#   host: app.mnc-company.com         -> your real domain
#   certificate-arn: ...REPLACE-ME    -> your ACM cert ARN
notepad "k8s\prod\services-ingress.yaml"
```

After editing:

```powershell
$DB = aws ssm get-parameter --name "/mnc-app/prod/db/password" `
    --with-decryption --query "Parameter.Value" --output text --region ap-south-1
kubectl create secret generic app-db-secret "--from-literal=DB_PASSWORD=$DB" `
    --namespace=prod --dry-run=client -o yaml | kubectl apply -f -
Remove-Variable DB

kubectl apply -f k8s\prod\
kubectl get pods -n prod -w
```

---

## Day-to-Day Operations

### Check pod status across environments

```powershell
kubectl get pods -n dev
kubectl get pods -n staging
kubectl get pods -n prod
```

### View logs

```powershell
# Follow backend logs in dev
kubectl logs -f deployment/backend -n dev

# Last 100 lines from prod
kubectl logs deployment/backend -n prod --tail=100

# Specific pod
kubectl logs <pod-name> -n prod
```

### Roll back a broken prod deployment

```powershell
kubectl rollout history deployment/backend  -n prod   # see revision numbers
kubectl rollout undo deployment/backend  -n prod       # roll back to previous
kubectl rollout undo deployment/frontend -n prod

# Watch rollback progress
kubectl rollout status deployment/backend -n prod

# Confirm which image is now running
kubectl get pods -n prod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

### Scale manually

```powershell
kubectl scale deployment backend --replicas=5 -n prod
```

### Check resource usage

```powershell
kubectl top pods -n prod
kubectl top nodes
```

### Destroy when done practicing (saves cost)

```powershell
# Always delete K8s resources first, then run terraform destroy
kubectl delete -f k8s\dev\

Set-Location "infra\environments\dev"
terraform destroy `
    -var-file="terraform.tfvars" `
    -var="db_password=DevPass123!"
# Type 'yes' when prompted
Set-Location "C:\Projects\mnc-devops-project"
```

---

## Troubleshooting

### "terraform is not recognized"

```powershell
# Refresh PATH without closing PowerShell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
terraform version
```

If still not found, close all PowerShell windows and open a new one.

### "Pods stuck in Pending"

```powershell
kubectl describe pod <pod-name> -n dev
# Look at "Events:" at the bottom
```

| Events message | Fix |
|---|---|
| `Insufficient cpu` | `kubectl top nodes` — nodes are full, scale up node group |
| `0/2 nodes are available` | EKS nodes not ready yet — wait 3 minutes |
| `did not match node selector` | Node count too low for anti-affinity rules |

### "ImagePullBackOff — ECR pull fails"

```powershell
# Verify ECR read policy is on the node role
aws iam list-attached-role-policies `
    --role-name mnc-app-dev-eks-node-role `
    --query "AttachedPolicies[].PolicyName"
# Must include: AmazonEC2ContainerRegistryReadOnly
```

### "SonarQube Quality Gate FAILED"

Open `http://localhost:9000` (SSM tunnel must be running) → Projects → mnc-app → look at the Quality Gate status.

| Failure | Fix |
|---|---|
| Line coverage below 70% | Add unit tests in `ProductServiceTest.java` |
| Bugs or Code Smells | Fix the issues flagged in SonarQube UI |
| Reliability rating D | Usually null pointer risks — fix in code |

### "ALB stuck at pending after ingress apply"

```powershell
# Check ALB controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=30

# Common fix: re-run Step 6 (IRSA role may need updating)
```

### "aws ssm start-session fails — TargetNotConnected"

```powershell
# Check instance is running
aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mnc-app-jenkins-master" `
    --query "Reservations[0].Instances[0].State.Name" `
    --output text

# Check SSM agent is registered
# AWS Console → Systems Manager → Fleet Manager → your instance should appear
# If not: check the Jenkins IAM role has AmazonSSMManagedInstanceCore
```

### "Pods crash immediately with secret app-db-secret not found"

This means the Kubernetes Secret was not injected before the pod tried to start. The Jenkinsfile `deployToEnvironment()` function injects it automatically during a pipeline run, but if you applied manifests manually, run this first:

```powershell
$ENV_NAME = "dev"   # change to staging or prod as needed
$DB_PASS = aws ssm get-parameter `
    --name "/mnc-app/$ENV_NAME/db/password" `
    --with-decryption --query "Parameter.Value" --output text --region ap-south-1

kubectl create secret generic app-db-secret `
    "--from-literal=DB_PASSWORD=$DB_PASS" `
    --namespace=$ENV_NAME `
    --dry-run=client -o yaml | kubectl apply -f -

Remove-Variable DB_PASS
kubectl rollout restart deployment/backend -n $ENV_NAME
```

### "terraform init fails — Backend configuration changed"

This happens when you have a stale `.terraform/` folder from a previous init with different backend settings. Fix:

```powershell
# Delete the cached backend config and reinitialise
Remove-Item -Recurse -Force "infra\environments\dev\.terraform"
Remove-Item -Force "infra\environments\dev\.terraform.lock.hcl" -ErrorAction SilentlyContinue

Set-Location "infra\environments\dev"
terraform init
```

### "Jenkins ALB returns connection refused on port 443"

Expected for the lab. The HTTPS listener is only created when `acm_certificate_arn` is set in `terraform.tfvars`. Use `http://` for the lab. To enable HTTPS, add this to your tfvars and re-apply:

```hcl
# In infra/environments/dev/terraform.tfvars
acm_certificate_arn = "arn:aws:acm:ap-south-1:YOUR_ACCOUNT:certificate/YOUR-CERT-UUID"
```

---

## Estimated AWS Cost

Approximate for `ap-south-1`, running **8 hours/day** (study sessions):

| Resource | Spec | Est. cost/month |
|---|---|---|
| EKS Control Plane | Managed | ~₹6,000 |
| EC2 nodes dev | 2× t3.medium SPOT | ~₹650 |
| Jenkins EC2 | 1× t3.large | ~₹1,800 |
| RDS dev | db.t3.micro | ~₹1,150 |
| NAT Gateways | 2× HA | ~₹5,300 |
| ALBs | Jenkins + app | ~₹1,500 |
| ECR | Storage + transfers | ~₹160 |
| **Total (dev only, 8hr/day)** | | **~₹16,560/month** |

**Biggest cost saving tip — destroy when not in use:**

```powershell
# End of study session (10 min)
kubectl delete -f k8s\dev\
terraform -chdir="infra\environments\dev" destroy `
    -var-file="terraform.tfvars" -var="db_password=DevPass123!" -auto-approve

# Start of next session (20 min)
terraform -chdir="infra\environments\dev" apply `
    -var-file="terraform.tfvars" -var="db_password=DevPass123!" -auto-approve
aws eks update-kubeconfig --region ap-south-1 --name mnc-app-dev-cluster
kubectl apply -f k8s\dev\
```

This alone reduces cost by ~90% if you study 2–3 hours a day instead of leaving infra running 24/7.

---

## Quick Reference — Most Used Commands

```powershell
# ── kubectl ────────────────────────────────────────────────────────────────
kubectl get pods -n dev                                  # list pods
kubectl get pods -n dev -w                               # watch (Ctrl+C to stop)
kubectl logs -f deployment/backend -n dev                # follow logs
kubectl describe pod <name> -n dev                       # debug a pod
kubectl exec -it deployment/backend -n dev -- sh         # shell into pod
kubectl rollout undo deployment/backend -n prod          # rollback
kubectl rollout status deployment/backend -n prod        # rollout progress
kubectl top pods -n prod                                 # CPU/memory usage
kubectl top nodes                                        # node usage

# ── terraform ─────────────────────────────────────────────────────────────
terraform plan    -var-file="terraform.tfvars" -var="db_password=X"
terraform apply   -var-file="terraform.tfvars" -var="db_password=X"
terraform destroy -var-file="terraform.tfvars" -var="db_password=X"
terraform output                                          # all outputs

# ── aws ───────────────────────────────────────────────────────────────────
# Reconnect kubectl after restarting PowerShell
aws eks update-kubeconfig --region ap-south-1 --name mnc-app-dev-cluster

# Get Jenkins initial password
aws ssm get-parameter --name "/mnc-app/jenkins/initial-password" `
    --with-decryption --query "Parameter.Value" --output text --region ap-south-1

# ── SSM tunnel for SonarQube (run in a separate PowerShell window) ─────────
$JENKINS_ID = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mnc-app-jenkins-master" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text --region ap-south-1

aws ssm start-session `
    --target $JENKINS_ID `
    --document-name AWS-StartPortForwardingSession `
    --parameters "portNumber=9000,localPortNumber=9000" `
    --region ap-south-1
# Then open: http://localhost:9000 in your browser
```
