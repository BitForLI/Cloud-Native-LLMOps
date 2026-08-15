# ECS module

Creates the Fargate cluster, hardened API/Worker task definitions, rolling ECS
services, container health checks, deployment circuit breakers, private task
networking, and retained CloudWatch log groups. It consumes networking, IAM,
ECR, ALB, queue, and data-module outputs.
