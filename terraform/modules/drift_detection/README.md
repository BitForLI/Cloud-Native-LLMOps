# Drift detection

Creates a dedicated GitHub OIDC role for read-only production Terraform plans.
It can read exactly one state object, inspect control-plane configuration, and
publish one metric namespace. It cannot read application secrets, DynamoDB
items, Parameter Store values, or mutate infrastructure.

The workflow runs with `-lock=false`, so the auditor never writes a state lock.
Raw state and plan values remain ephemeral; retained reports contain only
resource addresses, action types, and policy classifications.
