output "vpc_id" {
  description = "VPC ID — passed to EKS, RDS, Jenkins modules"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (used for ALB and NAT gateways)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (used for EKS nodes, RDS, Jenkins EC2)"
  value       = aws_subnet.private[*].id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}
