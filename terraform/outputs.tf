output "alb_dns_name" {
  description = "The URL to access your app — paste this in your browser!"
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "asg_name" {
  value = aws_autoscaling_group.main.name
}

output "rds_endpoint" {
  description = "Database connection endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}
output "vpc_id" {
  value = aws_vpc.main.id
}