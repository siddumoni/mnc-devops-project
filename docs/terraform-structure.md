# MNC App — Terraform Structure Explained

---

## 1. Overall Structure

```
infra/
├── main.tf          ← root module (wires sub-modules, NO backend block)
├── variables.tf     ← root variable declarations
├── outputs.tf
├── modules/
│   ├── vpc/
│   ├── ec2-jenkins/
│   ├── ecr/
│   ├── eks/
│   └── rds/
└── environments/
    ├── dev/
    │   ├── main.tf          ← has backend block + calls root module
    │   ├── variables.tf
    │   └── terraform.tfvars
    ├── staging/
    └── prod/
```

---

## 2. Where You Run Terraform

You always run `terraform init` and `terraform apply` from inside the environment folder:

```
infra/environments/dev/
```

This folder is the **real root** — it has the S3 backend block. If you tried running
terraform from `infra/` directly, it would fail because `infra/main.tf` has no backend
block and no provider block. It is designed to be called as a module, not executed directly.

---

## 3. The Three-Layer Call Chain

```
environments/dev/main.tf        ← you run terraform HERE
  └── calls module "dev" {
        source = "../../"        ← points to infra/main.tf
      }
        └── infra/main.tf       ← root module (no backend)
              ├── calls module "vpc"
              ├── calls module "jenkins"
              ├── calls module "ecr"
              ├── calls module "eks"
              └── calls module "rds"
```

---

## 4. How Modules Are Connected Inside `infra/main.tf`

Outputs from one module feed as inputs into another. Terraform resolves the order
automatically based on these dependencies.

```hcl
module "vpc" {
  source = "./modules/vpc"
  ...
}

module "jenkins" {
  source            = "./modules/ec2-jenkins"
  vpc_id            = module.vpc.vpc_id                    # ← from vpc
  private_subnet_id = module.vpc.private_subnet_ids[0]    # ← from vpc
  public_subnet_ids = module.vpc.public_subnet_ids         # ← from vpc
}

module "eks" {
  source           = "./modules/eks"
  vpc_id           = module.vpc.vpc_id                            # ← from vpc
  jenkins_sg_id    = module.jenkins.jenkins_security_group_id    # ← from jenkins
  jenkins_role_arn = module.jenkins.jenkins_role_arn             # ← from jenkins
  alb_sg_id        = aws_security_group.alb.id                   # ← direct resource
}

module "rds" {
  source         = "./modules/rds"
  vpc_id         = module.vpc.vpc_id
  eks_node_sg_id = module.eks.node_security_group_id    # ← from eks
  jenkins_sg_id  = module.jenkins.jenkins_security_group_id
}
```

The dependency graph flows like this:

```
vpc
 ├──► jenkins  (needs vpc_id, subnet IDs)
 │       └──► eks  (needs jenkins_sg_id, jenkins_role_arn)
 │                  └──► rds  (needs eks_node_sg_id)
 └──► eks  (also needs vpc_id, subnet IDs directly)
 └──► rds  (also needs vpc_id, subnet IDs directly)
```

Terraform sees these cross-module references and automatically creates resources in the
correct order. You never need to manually specify `depends_on` between modules because
the output-to-input wiring tells Terraform everything it needs to know.

---

## 5. The Three Layers of Variables

Every layer has its own `variables.tf` and each serves a different purpose.

### Layer 1 — Environment (`environments/dev/variables.tf`)

Declares all the variables that the environment's `main.tf` will receive from
`terraform.tfvars`. These are the things that differ per environment.

```hcl
variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "aws_account_id"      { type = string }
variable "vpc_cidr"            { type = string }
variable "node_instance_types" { type = list(string) }
variable "capacity_type"       { type = string }
variable "db_password"         { type = string; sensitive = true }
# ... 20+ more
```

### Layer 2 — Root module (`infra/variables.tf`)

Declares the same set again. This is required because when `environments/dev/main.tf`
calls `module "dev" { source = "../../" }`, the root module needs its own `variables.tf`
to receive those values being passed in.

```hcl
variable "project_name"  { type = string }
variable "environment"   { type = string }
variable "vpc_cidr"      { type = string }
variable "capacity_type" { type = string; default = "ON_DEMAND" }
variable "db_password"   { type = string; sensitive = true }
# ... same set as environment layer
```

### Layer 3 — Sub-module (e.g. `modules/eks/variables.tf`)

Each sub-module declares only the variables it actually uses. It does not know or care
about variables meant for other modules.

```hcl
variable "cluster_name"        { type = string }
variable "kubernetes_version"  { type = string; default = "1.35" }
variable "jenkins_role_arn"    { type = string }
variable "jenkins_sg_id"       { type = string }
variable "node_instance_types" { type = list(string) }
# ... only what eks needs
```

### Where the Actual Values Come From — `terraform.tfvars`

```hcl
# environments/dev/terraform.tfvars
project_name        = "mnc-app"
environment         = "dev"
aws_account_id      = "204803374292"
vpc_cidr            = "10.10.0.0/16"
capacity_type       = "SPOT"
node_instance_types = ["t3.medium"]
desired_nodes       = 2
```

You pass this file at apply time:

```powershell
terraform apply -var-file="terraform.tfvars" -var="db_password=YourPass123!"
```

Terraform reads these values, matches them against `environments/dev/variables.tf`
declarations, then passes them down the chain through every layer.

---

## 6. How a Single Value Travels Through All Layers

Tracing `vpc_cidr = "10.10.0.0/16"` from `terraform.tfvars` all the way to the actual
AWS resource:

```
terraform.tfvars
  vpc_cidr = "10.10.0.0/16"
      ↓
environments/dev/variables.tf  →  declares  variable "vpc_cidr"
      ↓
environments/dev/main.tf  →  passes it into the root module:
  module "dev" {
    source   = "../../"
    vpc_cidr = var.vpc_cidr       # "10.10.0.0/16"
  }
      ↓
infra/variables.tf  →  declares  variable "vpc_cidr"
      ↓
infra/main.tf  →  passes it into the vpc sub-module:
  module "vpc" {
    source   = "./modules/vpc"
    vpc_cidr = var.vpc_cidr       # still "10.10.0.0/16"
  }
      ↓
modules/vpc/variables.tf  →  declares  variable "vpc_cidr"
      ↓
modules/vpc/main.tf  →  uses it in the actual resource:
  resource "aws_vpc" "main" {
    cidr_block = var.vpc_cidr     # "10.10.0.0/16" reaches AWS here
  }
```

The value passes through **five files** before it reaches the AWS resource. This
verbosity is the price of proper environment isolation — the same module code can serve
dev, staging, and prod with completely different values without any copy-pasting.

---

## 7. Why the Backend Block Cannot Live in `infra/main.tf`

This is a Terraform hard rule: **a called module is not allowed to have a backend
configuration.** Only the root — the directory where you actually run `terraform init`
— can define where state is stored.

So each environment folder has its own backend block pointing to its own state key:

```hcl
# environments/dev/main.tf
backend "s3" {
  bucket = "mnc-app-terraform-state-204803374292"
  key    = "environments/dev/terraform.tfstate"    # dev's own state file
}

# environments/prod/main.tf
backend "s3" {
  bucket = "mnc-app-terraform-state-204803374292"
  key    = "environments/prod/terraform.tfstate"   # prod's own state file
}
```

Both point at the **same module code** in `infra/main.tf` and `infra/modules/`. The
only difference between environments is what is in their `terraform.tfvars`:

| Setting          | dev          | staging      | prod         |
|------------------|--------------|--------------|--------------|
| `capacity_type`  | SPOT         | SPOT         | ON_DEMAND    |
| `db_instance_class` | db.t3.micro | db.t3.small | db.t3.small |
| `desired_nodes`  | 2            | 2            | 3            |
| `node_instance_types` | t3.medium | t3.medium  | t3.large     |
| `create_ecr`     | true         | false        | false        |

This is the entire point of the structure: **share the code, isolate the state.**

---

## 8. Quick Reference — Variable Flow Summary

```
terraform.tfvars          (values live here)
      ↓
environments/dev/
  variables.tf            (declares what tfvars can supply)
  main.tf                 (passes vars into root module)
      ↓
infra/
  variables.tf            (root module receives them)
  main.tf                 (passes specific vars into each sub-module)
      ↓
infra/modules/<name>/
  variables.tf            (sub-module declares only what it needs)
  main.tf                 (uses var.* to create AWS resources)
      ↓
AWS Resource              (value finally used here)
```
