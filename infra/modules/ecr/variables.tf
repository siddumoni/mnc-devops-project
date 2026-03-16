variable "project_name"      { type = string }
variable "jenkins_role_arn"  { type = string }
variable "eks_node_role_arn" { type = string }
variable "tags"              { 
    type = map(string) 
    default = {} 
}
