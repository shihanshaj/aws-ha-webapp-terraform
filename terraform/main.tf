# ============================================================
# PROVIDER + DATA SOURCES
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Automatically get the list of availability zones in our region
data "aws_availability_zones" "available" {
  state = "available"
}

# Get the latest Amazon Linux 2 AMI (the OS for our servers)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# ============================================================
# VPC — Your Private Network on AWS
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.app_name}-vpc"
  }
}

# ============================================================
# SUBNETS — Sections of your network
# Public = internet can reach them (ALB lives here)
# Private = no direct internet (servers + DB live here)
# ============================================================

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true # Instances here get a public IP

  tags = {
    Name = "${var.app_name}-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.app_name}-private-${count.index + 1}"
  }
}

# ============================================================
# INTERNET GATEWAY — The door between your VPC and the internet
# ============================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-igw"
  }
}

# ============================================================
# NAT GATEWAY — Lets private servers reach internet (for updates)
# but internet CANNOT reach them directly
# We only need 1 NAT GW to save money (production uses 3)
# ============================================================

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${var.app_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # NAT lives in first public subnet

  tags = {
    Name = "${var.app_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# ============================================================
# ROUTE TABLES — GPS directions for network traffic
# ============================================================

# Public route table: sends internet traffic to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.app_name}-public-rt"
  }
}

# Connect public subnets to public route table
resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table: sends internet traffic to NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.app_name}-private-rt"
  }
}

# Connect private subnets to private route table
resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# SECURITY GROUPS — Firewall rules
# Think of these as bouncers for each resource
# ============================================================

# ALB Security Group: allows HTTP from anywhere on the internet
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow HTTP traffic to load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from internet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.app_name}-alb-sg"
  }
}

# EC2 Security Group: ONLY allows traffic from the ALB (not internet directly)
resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-ec2-sg"
  description = "Allow traffic only from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow HTTP from ALB only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-ec2-sg"
  }
}

# RDS Security Group: ONLY allows traffic from EC2 servers
resource "aws_security_group" "rds" {
  name        = "${var.app_name}-rds-sg"
  description = "Allow DB traffic only from EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id] # Only from our servers!
    description     = "Allow PostgreSQL from EC2 only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-rds-sg"
  }
}

# ============================================================
# APPLICATION LOAD BALANCER — Traffic distributor
# Receives all requests, splits them across your servers
# ============================================================

resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false # Public-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # Spans all 3 public subnets

  tags = {
    Name = "${var.app_name}-alb"
  }
}

# Target Group: the group of servers the ALB sends traffic to
resource "aws_lb_target_group" "main" {
  name     = "${var.app_name}-tg2"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.app_name}-tg2"
  }
}

# Listener: tells ALB to forward port 80 traffic to our target group
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ============================================================
# IAM ROLE — Permissions for EC2 servers
# Lets servers talk to other AWS services
# ============================================================

resource "aws_iam_role" "ec2" {
  name = "${var.app_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ============================================================
# LAUNCH TEMPLATE — Blueprint for every new EC2 server
# ============================================================

resource "aws_launch_template" "main" {
  name_prefix   = "${var.app_name}-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  # This script runs automatically when each server boots up
  user_data = base64encode(file("../app/user_data.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.app_name}-server"
    }
  }
}

# ============================================================
# AUTO SCALING GROUP — Manages your fleet of servers
# Creates/destroys servers automatically based on demand
# ============================================================

resource "aws_autoscaling_group" "main" {
  name                = "${var.app_name}-asg"
  vpc_zone_identifier = aws_subnet.private[*].id # Servers in private subnets
  min_size            = var.min_instances
  max_size            = var.max_instances
  desired_capacity    = var.min_instances

  target_group_arns = [aws_lb_target_group.main.arn]
  health_check_type = "ELB" # Use load balancer health checks

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.app_name}-server"
    propagate_at_launch = true
  }
}

# Scale UP when CPU > 70%
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.app_name}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.main.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.app_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }
}

# Scale DOWN when CPU < 30%
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.app_name}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.main.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.app_name}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }
}

# ============================================================
# RDS AURORA POSTGRESQL — Your database
# Multi-AZ = data is safe even if one zone fails
# ============================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.app_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.app_name}-postgres"
  engine                 = "postgres"
  engine_version         = "15.8"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  multi_az               = true
  publicly_accessible    = false

  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = {
    Name = "${var.app_name}-postgres"
  }
}

# ============================================================
# CLOUDWATCH — Monitoring dashboard
# ============================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.app_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ALB Request Count"
          region  = var.aws_region
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
          annotations = {
            horizontal = []
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ASG CPU Utilization"
          region  = var.aws_region
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.main.name]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = {
            horizontal = []
          }
        }
      }
    ]
  })
}