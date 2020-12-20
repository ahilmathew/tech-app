
variable "access_key" {
    type=string
}
variable "secret_key" {
    type=string
}
variable "region" {
    type=string
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "db_instance_type" {
  type = string
  default = "db.t2.micro"
}
variable "database_name" {
  type    = string
  default = "app"
}
variable "database_username" {
  type    = string
  default = "postgres"
}
variable "db_multiaz" {
  default = true
}
variable "db_identifier_prefix" {
  type = string
  default = "techapp-db-1"
}
variable "db_skip_final_snapshot" {
  type = string
  default = true
}
variable "ingress_cidrs" {
  type    = list(string)
  default = ["121.74.104.60/32"]
}
variable "db_max_allocated_storage" {
  type = string
  default = "30"
}
variable "min_asg_size" {
  type = string
  default = "2"
}
variable "max_asg_size" {
  type = string
  default = "5"
}
# Get availability zones for the region specified in var.region
data "aws_availability_zones" "available" {}

# Search the latest amazon linux 2 AMI.
data "aws_ami" "amazon-linux-2" {
    most_recent = true

    filter {
    name   = "owner-alias"
    values = ["amazon"]
    }

    filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
    }
    owners = ["amazon"]
}

# Configure AWS connection, secrets are in terraform.tfvars
provider "aws" {
  access_key = var.access_key
  secret_key = var.secret_key
  region     = var.region
}


resource "aws_vpc" "techapp_vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "techapp-vpc"
  }
}

resource "aws_subnet" "public_subnets" {
  count = length(data.aws_availability_zones.available.names)
  vpc_id = aws_vpc.techapp_vpc.id
  cidr_block = "10.20.${10+count.index}.0/24"
  availability_zone= data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "PublicSubnet"
  }
}

resource "aws_subnet" "private_subnets" {
  count = length(data.aws_availability_zones.available.names)
  vpc_id = aws_vpc.techapp_vpc.id
  cidr_block = "10.20.${20+count.index}.0/24"
  availability_zone= data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "PrivateSubnet"
  }
}

# Create a new internet gateway for the VPC
resource "aws_internet_gateway" "techapp_igw_public" {
  vpc_id = aws_vpc.techapp_vpc.id
  tags = {
    Name = "main"
  }
}

# Add a route to access internet gateway
resource "aws_default_route_table" "main" {
  default_route_table_id = aws_vpc.techapp_vpc.default_route_table_id
  tags = {
    "Name" = "main"
  }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.techapp_igw_public.id
  }
}
# Create NAT gateway and related resources so that EC2 instances on the private subnet can talk to the internet
resource "aws_eip" "nat" {
  vpc      = true
}

# NAT Gateway is created on one of the public sunets.
resource "aws_nat_gateway" "ngw" {
  allocation_id = aws_eip.nat.id
  subnet_id = element(aws_subnet.public_subnets.*.id, 1)
}

# Create a new route table to forward traffic from private subnets to the NAT gateway
resource "aws_route_table" "private_route_table" { #5
  vpc_id = aws_vpc.techapp_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngw.id
  }

  tags = {
    Names = "rtb-ngw"
  }
}
# Associate route table to all private subnets. This will allow traffic(to "0.0.0.0/0") from all private subnets
# to go via the NAT gateway.
resource "aws_route_table_association" "private" {
  count = length(data.aws_availability_zones.available.names)
  subnet_id = element(aws_subnet.private_subnets.*.id, count.index)
  route_table_id = aws_route_table.private_route_table.id
}

# Create security group for the ALB
resource "aws_security_group" "techapp_alb_sg" {
  name = "teachapp-alb-sg"
  vpc_id  = aws_vpc.techapp_vpc.id

  # Allow all outbound
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound HTTP from only the configured cidrs
  ingress {
    from_port = "80"
    to_port = "80"
    protocol = "tcp"
    cidr_blocks = var.ingress_cidrs
  }
}

# Create ALB on all of the public subnets
resource "aws_lb" "techapp_alb" {
  name               = "techapp-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.techapp_alb_sg.id]
  subnets            = aws_subnet.public_subnets.*.id

  tags = {
    Name = "techapp_alb"
  }
}

# Listener for ALB. Default forward action to the frontend EC2 target group
resource "aws_lb_listener" "techapp_front_end_listener" {
  load_balancer_arn = aws_lb.techapp_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.techapp_frontend_tg.arn
  }
}

# Create Target Group for alb. EC2 instances created by the Auto Scaling Group will be automatically
# registered to this target group.
resource "aws_lb_target_group" "techapp_frontend_tg" {
  name        = "techapp-frontend-tg"
  port        = 3000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.techapp_vpc.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 5
    interval            = 30
    path                = "/healthcheck/"
    port                = 3000
    protocol            = "HTTP"
    matcher             = "200"
  }
}

# Create autoscaling policy for the frontend. Autoscale when average CPU load > 80%
resource "aws_autoscaling_policy" "techapp_frontend_asg_policy" {
  name                   = "techapp_frontend_asg_policy"
  policy_type            = "TargetTrackingScaling"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.teachapp-asg.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }
}

# Create an autoscaling group to launch atleast 2 instances on different availability zones.
resource "aws_autoscaling_group" "teachapp-asg" {
  name = "teachapp-asg"
  depends_on = [aws_db_instance.techapp_postgresql]
  launch_configuration = aws_launch_configuration.teachapp_lc.id
  vpc_zone_identifier = aws_subnet.private_subnets.*.id

  min_size = var.min_asg_size
  max_size = var.max_asg_size
  #Associate ASG with the target group.
  target_group_arns = [aws_lb_target_group.techapp_frontend_tg.arn]
  health_check_type = "ELB"

  tag {
    key = "Name"
    value = "teachapp-ASG"
    propagate_at_launch = true
  }
}

# Create the final conf.toml file for the TechApp.
data "template_file" "techapp_conf" {
  template = file("config/conf.toml")
  vars = {
    db_password = aws_secretsmanager_secret_version.db_password.secret_string
    db_host     = aws_db_instance.techapp_postgresql.address
    db_name     = aws_db_instance.techapp_postgresql.name
  }
}
# Create a template file for the user data that is passed to the user_data in the launch configuration.
data "template_file" "ec2_userdata" {
  template = <<EOF
  #! /bin/bash
  set -x
  # Update yum packages
  sudo yum update -y
  # Install and start docker
  sudo amazon-linux-extras install docker
  sudo service docker start
  # Add ec2-user to docker group so that the user can run commands without sudo
  sudo usermod -a -G docker ec2-user
  # Enable docker on startup
  sudo chkconfig docker on
  # Copy the conf.toml file to ec2 instance
  echo ${base64encode(data.template_file.techapp_conf.rendered)} | base64 --decode > /home/ec2-user/conf.toml
  sudo docker network create appnetwork --opt com.docker.network.bridge.name=br_app_access
  sudo docker pull servian/techchallengeapp
  sleep 3
  sudo docker run --rm --name techapp --network=appnetwork -p 3000:3000 -v /home/ec2-user/conf.toml:/TechChallengeApp/conf.toml -d servian/techchallengeapp updatedb -s
  sleep 3
  sudo docker run --name techapp --network=appnetwork -p 3000:3000 -v /home/ec2-user/conf.toml:/TechChallengeApp/conf.toml -d servian/techchallengeapp serve
  sleep 10
  touch _INIT_COMPLETE_
  EOF
}

# Create launch configuration
resource "aws_launch_configuration" "teachapp_lc" {
  name_prefix     = "teachapp-lc-"
  image_id        = data.aws_ami.amazon-linux-2.id
  instance_type   = var.instance_type
  security_groups = [aws_security_group.teachapp_lc_sg.id]
  user_data       = data.template_file.ec2_userdata.rendered

  lifecycle {
    create_before_destroy = true
  }
}

# Create security group that's applied the launch configuration
resource "aws_security_group" "teachapp_lc_sg" {
  name    = "teachapp_lc_sg"
  vpc_id  = aws_vpc.techapp_vpc.id

  # Inbound access on port 3000 for the ALB security group. TechChallengeApp runs on port 3000.
  ingress {
    from_port = "3000"
    to_port = "3000"
    protocol = "tcp"
    security_groups = [aws_security_group.techapp_alb_sg.id]
  }
  # Egress to anywhere. This traffic will be route via the NAT gateway.
  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

# Create Postgres RDS Database.
# Create security group that's applied the Postgres RDS Database
resource "aws_security_group" "teachapp_rds_sg" {
  name    = "teachapp_rds_sg"
  vpc_id  = aws_vpc.techapp_vpc.id

  # Inbound HTTP from EC2 instances.
  ingress {
    from_port = "5432"
    to_port = "5432"
    protocol = "tcp"
    security_groups = [aws_security_group.teachapp_lc_sg.id]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

# Private Subnet group for the database.
resource "aws_db_subnet_group" "postgres_subnet_group" {
  name_prefix = "techapp-db-subnet-group-"
  subnet_ids  = aws_subnet.private_subnets.*.id

  tags = {
    Name = "techapp-db-subnet-group"
  }
}
# Generate a random password for the postgres database.
resource "random_password" "password" {
  length = 16
  special = false
}

# Create a secret in AWS Secrets manager. Only authorized users to the AWS account will have access to this.
resource "aws_secretsmanager_secret" "postgres_db_password_secret" {
  name_prefix = "postgres-db-password-secret-"
}

# Store the random password in the Secret in AWS Secrets Manager.
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.postgres_db_password_secret.id
  secret_string = random_password.password.result
}

# Create the RDS Postgres database.
resource "aws_db_instance" "techapp_postgresql" {
  allocated_storage               = 20
  max_allocated_storage           = var.db_max_allocated_storage
  engine                          = "postgres"
  engine_version                  = 10.7
  identifier_prefix               = var.db_identifier_prefix
  instance_class                  = var.db_instance_type
  name                            = var.database_name
  password                        = aws_secretsmanager_secret_version.db_password.secret_string
  username                        = var.database_username
  backup_retention_period         = 0
  skip_final_snapshot             = var.db_skip_final_snapshot
  multi_az                        = var.db_multiaz
  vpc_security_group_ids          = [aws_security_group.teachapp_rds_sg.id]
  db_subnet_group_name            = aws_db_subnet_group.postgres_subnet_group.id

  tags = {
    Name  = "techapp-pgsql"
  }
}
# ALB public DNS address to access the application.
output "application_url" {
  value = "http://${aws_lb.techapp_alb.dns_name}/"
}