locals {
  common_tags = merge(var.tags, { Component = "compute" })
  valid_fargate_sizes = toset(flatten([
    [for memory in [512, 1024, 2048] : "256:${memory}"],
    [for memory in range(1024, 4097, 1024) : "512:${memory}"],
    [for memory in range(2048, 8193, 1024) : "1024:${memory}"],
    [for memory in range(4096, 16385, 1024) : "2048:${memory}"],
    [for memory in range(8192, 30721, 1024) : "4096:${memory}"],
    [for memory in range(16384, 61441, 4096) : "8192:${memory}"],
    [for memory in range(32768, 122881, 8192) : "16384:${memory}"],
  ]))

  api_environment = [
    { name = "APP_ENV", value = var.environment },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "LLM_PROVIDER", value = "bedrock" },
    { name = "JOB_BACKEND", value = "aws" },
    { name = "BEDROCK_MODEL_ID", value = var.bedrock_model_id },
    { name = "ARTIFACT_BUCKET_NAME", value = var.artifact_bucket_name },
    { name = "JOB_TABLE_NAME", value = var.job_table_name },
    { name = "INFERENCE_QUEUE_URL", value = var.inference_queue_url },
    { name = "LOG_LEVEL", value = var.log_level },
  ]
  worker_environment = concat(local.api_environment, [
    { name = "JOB_MAX_RECEIVE_COUNT", value = tostring(var.job_max_receive_count) },
    { name = "WORKER_HEARTBEAT_PATH", value = "/tmp/llmops-worker-heartbeat" },
    { name = "WORKER_HEARTBEAT_INTERVAL_SECONDS", value = "30" },
    { name = "WORKER_HEARTBEAT_MAX_AGE_SECONDS", value = "90" },
  ])
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/api"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Service = "api" })
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}/worker"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Service = "worker" })
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "Private network boundary for ${var.name} ECS tasks"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name}-tasks" })
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.alb_security_group_id
  description                  = "API traffic from the application load balancer"
  ip_protocol                  = "tcp"
  from_port                    = var.api_container_port
  to_port                      = var.api_container_port
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS access to AWS APIs through NAT or VPC endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.api_cpu)
  memory                   = tostring(var.api_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "api-tmp"
  }

  container_definitions = jsonencode([{
    name                   = "api"
    image                  = "${var.api_repository_url}:${var.api_image_tag}"
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    stopTimeout            = 30

    portMappings = [{
      name          = "http"
      containerPort = var.api_container_port
      hostPort      = var.api_container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    environment = local.api_environment
    mountPoints = [{
      sourceVolume  = "api-tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]
    secrets = [
      for name in sort(keys(var.api_secrets)) :
      { name = name, valueFrom = var.api_secrets[name] }
    ]

    linuxParameters = {
      initProcessEnabled = true
    }

    healthCheck = {
      command = [
        "CMD-SHELL",
        "python -c \"import urllib.request; raise SystemExit(0 if urllib.request.urlopen('http://127.0.0.1:${var.api_container_port}/health', timeout=2).status == 200 else 1)\"",
      ]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "api"
      }
    }
  }])

  lifecycle {
    precondition {
      condition     = contains(local.valid_fargate_sizes, "${var.api_cpu}:${var.api_memory}")
      error_message = "api_cpu and api_memory must be a supported Fargate size."
    }
  }

  tags = merge(local.common_tags, { Service = "api" })
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.worker_cpu)
  memory                   = tostring(var.worker_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.worker_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "worker-tmp"
  }

  container_definitions = jsonencode([{
    name                   = "worker"
    image                  = "${var.worker_repository_url}:${var.worker_image_tag}"
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    stopTimeout            = 30
    portMappings           = []
    environment            = local.worker_environment
    mountPoints = [{
      sourceVolume  = "worker-tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]
    secrets = [
      for name in sort(keys(var.worker_secrets)) :
      { name = name, valueFrom = var.worker_secrets[name] }
    ]

    linuxParameters = {
      initProcessEnabled = true
    }

    healthCheck = {
      command     = ["CMD", "python", "-m", "services.worker.healthcheck"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }])

  lifecycle {
    precondition {
      condition     = contains(local.valid_fargate_sizes, "${var.worker_cpu}:${var.worker_memory}")
      error_message = "worker_cpu and worker_memory must be a supported Fargate size."
    }
  }

  tags = merge(local.common_tags, { Service = "worker" })
}

resource "aws_ecs_service" "api" {
  name                               = "${var.name}-api"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.api_desired_count
  launch_type                        = "FARGATE"
  platform_version                   = var.fargate_platform_version
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.tasks.id]
    subnets          = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = var.api_target_group_arn
    container_name   = "api"
    container_port   = var.api_container_port
  }

  tags = merge(local.common_tags, { Service = "api" })
}

resource "aws_ecs_service" "worker" {
  name                               = "${var.name}-worker"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.worker.arn
  desired_count                      = var.worker_desired_count
  launch_type                        = "FARGATE"
  platform_version                   = var.fargate_platform_version
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.tasks.id]
    subnets          = var.private_subnet_ids
  }

  tags = merge(local.common_tags, { Service = "worker" })
}
