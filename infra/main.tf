terraform {
  required_version = ">= 1.5.0"

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

# Package Lambda code (zip) from ../lambda-ai-gate
data "archive_file" "ai_gate_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda-ai-gate"
  output_path = "${path.module}/ai-gate-lambda.zip"
}

resource "aws_iam_policy" "lambda_ai_gate_policy" {
  name        = "lambda-ai-gate-policy"
  description = "Execution policy for task-tracker AI gate Lambda (logs + Bedrock, cost-aware)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1) CloudWatch Logs: basic Lambda logging
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },

      # 2) Amazon Bedrock: allow invoking ONLY the chosen small model in us-east-1
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ai_gate_attach" {
  role       = aws_iam_role.ai_gate_lambda_role.name
  policy_arn = aws_iam_policy.lambda_ai_gate_policy.arn
}

resource "aws_iam_role" "ai_gate_lambda_role" {
  name = "task-tracker-ai-gate-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ai_gate_lambda_basic" {
  role       = aws_iam_role.ai_gate_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "ai_gate" {
  function_name = "task-tracker-ai-gate"
  role          = aws_iam_role.ai_gate_lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.ai_gate_zip.output_path
  source_code_hash = data.archive_file.ai_gate_zip.output_base64sha256

  timeout = 10
  memory_size = 256
}

# Lookup default VPC (no NAT, low cost)
data "aws_vpcs" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpcs.default.ids[0]]
  }
}

# ECR repository for the task tracker API
resource "aws_ecr_repository" "task_tracker" {
  name                 = "task-tracker-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ECS cluster
resource "aws_ecs_cluster" "this" {
  name = "task-tracker-cluster"
}

# Security group for ALB (public HTTP)
resource "aws_security_group" "alb" {
  name        = "task-tracker-alb-sg"
  description = "ALB security group"
  vpc_id      = data.aws_vpcs.default.ids[0]

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for ECS tasks (only ALB can hit)
resource "aws_security_group" "ecs" {
  name        = "task-tracker-ecs-sg"
  description = "ECS tasks security group"
  vpc_id      = data.aws_vpcs.default.ids[0]

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB
resource "aws_lb" "this" {
  name               = "task-tracker-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "this" {
  name     = "task-tracker-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpcs.default.ids[0]

  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# IAM role for ECS task execution
resource "aws_iam_role" "task_execution" {
  name = "task-tracker-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS task definition (Fargate)
resource "aws_ecs_task_definition" "task_tracker" {
  family                   = "task-tracker-task"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "task-tracker-api"
      image     = "${aws_ecr_repository.task_tracker.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.task_tracker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_cloudwatch_log_group.task_tracker
  ]
}

resource "aws_cloudwatch_log_group" "task_tracker" {
  name              = "/ecs/task-tracker"
  retention_in_days = 7
}

# ECS service
resource "aws_ecs_service" "task_tracker" {
  name            = "task-tracker-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.task_tracker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "task-tracker-api"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http
  ]
}

resource "aws_iam_user" "ci" {
  name = "task-tracker-ci-user"
}

resource "aws_iam_user_policy_attachment" "ci_attach" {
  user       = aws_iam_user.ci.name
  policy_arn = aws_iam_policy.ci_ecr_ecs.arn
}

resource "aws_iam_access_key" "ci" {
  user = aws_iam_user.ci.name
}

resource "aws_iam_policy" "ci_ecr_ecs" {
  name        = "task-tracker-ci-ecr-ecs-policy"
  description = "Allow GitHub Actions to push to ECR, deploy ECS, and invoke AI gate Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.ai_gate.arn
        ]
      }
    ]
  })
}