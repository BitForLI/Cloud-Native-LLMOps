# Monitoring module

Creates a customer-KMS-encrypted SNS alarm topic, optional email subscriptions, CloudWatch
log-derived HTTP metrics, a production dashboard, and alarms for ALB errors and
latency, ECS saturation, SQS backlog/DLQ depth, and LLM error/latency signals.
The ECS panel also correlates running and desired task counts with utilization
so scaling activity is visible without leaving the operations dashboard.
When WAF is enabled, its blocked-request count is overlaid on the API traffic
panel for direct correlation with ALB request and target-error volume.
Blue/green environments monitor both target groups independently and export a
focused, fail-closed alarm set for release controllers.

Email subscriptions remain pending until each recipient confirms the AWS SNS
message. Missing traffic is treated as healthy for rate and latency alarms;
missing ECS telemetry is treated as breaching so disappeared tasks are visible.
The key and topic policies allow only this account's name-scoped CloudWatch
alarms to publish, protecting the service integration from confused deputies.
