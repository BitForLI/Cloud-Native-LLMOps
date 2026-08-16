# IAM module

Creates separate ECS execution, API task, Worker task, and GitHub deployment
roles. Runtime permissions are scoped to the concrete platform resources; the
GitHub role uses OIDC federation and never requires stored AWS access keys.

Deployment roles may optionally receive read-only access to concrete source
ECR repositories for cross-environment manifest promotion. Destination image
writes, source reads, ECS service updates, and role passing remain separately
scoped; wildcard repository inputs are rejected.

Promotion-only roles normally call only `PutImage`. When supply-chain signing
is enabled, they may also upload Cosign signature layers, but all writes remain
scoped to the two destination repositories. In
production, direct API `UpdateService` access is removed so CodeDeploy cannot
be bypassed; GitHub can still roll the headless Worker safely.

API and Worker task roles grant only the resource-agnostic X-Ray write actions
required by their co-located ADOT Collector. They do not grant remote sampling,
trace reads, or X-Ray administration.
