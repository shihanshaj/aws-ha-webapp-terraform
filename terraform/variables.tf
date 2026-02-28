variable "aws_region" {
  description = "AWS region to deploy everything in"
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name prefix for all resources"
  default     = "ha-webapp"
}

variable "vpc_cidr" {
  description = "IP range for our VPC"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "IP ranges for public subnets (one per AZ)"
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "IP ranges for private subnets (one per AZ)"
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "instance_type" {
  description = "EC2 size (t3.micro is free tier)"
  default     = "t3.micro"
}

variable "min_instances" {
  description = "Minimum number of servers always running"
  default     = 2
}

variable "max_instances" {
  description = "Maximum servers during high traffic"
  default     = 4
}

variable "db_name" {
  description = "Database name"
  default     = "appdb"
}

variable "db_username" {
  description = "Database admin username"
  default     = "dbadmin"
}

variable "db_password" {
  description = "Database password - change this!"
  default     = "CHANGE_ME_IN_PRODUCTION"
  sensitive   = true
}
