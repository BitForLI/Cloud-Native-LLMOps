# ECS module

Creates the Fargate cluster, hardened API/Worker task definitions, private task
networking, container health checks, and retained CloudWatch log groups. API
releases can use the default ECS rolling controller with circuit breaker or a
production CodeDeploy controller; the headless Worker retains rolling rollback.
It consumes networking, IAM, ECR, ALB, queue, and data-module outputs.
