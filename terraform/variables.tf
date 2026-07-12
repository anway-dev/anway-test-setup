variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "anway-demo"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "demo"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired" {
  description = "Desired EKS node count"
  type        = number
  default     = 3
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 6
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

# Secrets — never default, always from env TF_VAR_* or -var flags
variable "db_password" {
  description = "RDS master password — set via TF_VAR_db_password"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for auth-service — set via TF_VAR_jwt_secret"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password — set via TF_VAR_grafana_admin_password"
  type        = string
  sensitive   = true
}

variable "spinnaker_ui_password" {
  description = "Spinnaker Gate API password — set via TF_VAR_spinnaker_ui_password"
  type        = string
  sensitive   = true
}
