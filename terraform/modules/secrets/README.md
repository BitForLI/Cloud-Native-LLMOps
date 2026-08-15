# Secrets module

Creates a customer-managed, automatically rotating KMS key and an empty Secrets
Manager container for the API authentication token. It deliberately does not
create `aws_secretsmanager_secret_version`, so plaintext never enters Terraform
configuration, plans, or state.

After the first targeted apply, populate the secret with a cryptographically
random value of at least 32 characters. ECS resolves `AWSCURRENT` when a task
starts; after changing the value, force a new API deployment so running tasks
receive it.
