locals {
  common_tags = merge(var.tags, { Component = "blue-green-deployment" })
}

resource "aws_iam_role" "codedeploy" {
  name = "${var.name}-codedeploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codedeploy.amazonaws.com" }
    }]
  })
  tags = merge(local.common_tags, { Role = "codedeploy-ecs" })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "api" {
  compute_platform = "ECS"
  name             = "${var.name}-api"
  tags             = local.common_tags
}

resource "aws_codedeploy_deployment_group" "api" {
  app_name               = aws_codedeploy_app.api.name
  deployment_group_name  = "${var.name}-api"
  deployment_config_name = var.deployment_config_name
  service_role_arn       = aws_iam_role.codedeploy.arn

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = var.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = var.production_listener_arns
      }

      dynamic "target_group" {
        for_each = var.target_group_names
        content {
          name = target_group.value
        }
      }
    }
  }

  alarm_configuration {
    alarms                    = var.alarm_names
    enabled                   = true
    ignore_poll_alarm_failure = false
  }

  auto_rollback_configuration {
    enabled = true
    events = [
      "DEPLOYMENT_FAILURE",
      "DEPLOYMENT_STOP_ON_ALARM",
      "DEPLOYMENT_STOP_ON_REQUEST",
    ]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    green_fleet_provisioning_option {
      action = "DISCOVER_EXISTING"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.blue_termination_wait_minutes
    }
  }

  depends_on = [aws_iam_role_policy_attachment.codedeploy]
  tags       = local.common_tags
}
