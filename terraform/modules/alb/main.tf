locals {
  common_tags = merge(var.tags, { Component = "load-balancer" })
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ingress to the ${var.name} application load balancer"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP ingress and HTTPS redirect"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count = var.certificate_arn == null ? 0 : 1

  security_group_id = aws_security_group.alb.id
  description       = "Public HTTPS ingress"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "api" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward requests to private API tasks"
  ip_protocol       = "tcp"
  from_port         = var.api_container_port
  to_port           = var.api_container_port
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  idle_timeout               = var.idle_timeout_seconds

  tags = merge(local.common_tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.name}-api"
  port                 = var.api_container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${var.name}-api" })
}

resource "aws_lb_target_group" "api_alternate" {
  count = var.enable_blue_green ? 1 : 0

  name                 = "${var.name}-api-alt"
  port                 = var.api_container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${var.name}-api-alt" })
}

resource "aws_lb_listener" "http_forward" {
  count = var.certificate_arn == null ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = var.certificate_arn == null ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn == null ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
