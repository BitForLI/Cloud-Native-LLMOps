# IAM module

Creates separate ECS execution, API task, Worker task, and GitHub deployment
roles. Runtime permissions are scoped to the concrete platform resources; the
GitHub role uses OIDC federation and never requires stored AWS access keys.
