variable "project_name"       { type = string }
variable "environment"         { type = string }
variable "cluster_name"        { type = string }
variable "kubernetes_version"  {
  type    = string
  default = "1.35"
}
variable "vpc_id"              { type = string }
variable "public_subnet_ids"   { type = list(string) }
variable "private_subnet_ids"  { type = list(string) }
variable "jenkins_sg_id"       { type = string }
variable "alb_sg_id"           { type = string }
variable "ec2_key_name"        { type = string }
# ── NEW: Jenkins IAM role ARN ─────────────────────────────────────────────
# Required so the aws-auth ConfigMap can grant Jenkins kubectl access.
# Passed from infra/main.tf as module.jenkins.jenkins_role_arn.
variable "jenkins_role_arn" {
  type        = string
  description = "IAM role ARN of the Jenkins EC2 instance profile. Added to aws-auth so Jenkins can run kubectl."
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}
variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"
}
variable "desired_nodes" {
  type    = number
  default = 2
}
variable "min_nodes" {
  type    = number
  default = 1
}
variable "max_nodes" {
  type    = number
  default = 4
}
variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "tags" {
  type    = map(string)
  default = {}
}
