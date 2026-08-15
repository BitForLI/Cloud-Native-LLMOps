# CodeDeploy module

Creates the ECS CodeDeploy application, deployment group, service role, ALB
target-group pair, 10-percent canary policy, CloudWatch alarm stop conditions,
and automatic rollback. The prior blue task set remains available during the
post-shift bake window before termination.
