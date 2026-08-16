# Cost control module

Creates a monthly account-level AWS cost budget with an early actual-spend
warning and a forecast-overrun warning. Notifications use the platform's
encrypted SNS operations topic. This is an alerting guardrail, not a hard
service shutdown: automatic shutdown could destroy availability or data.

Use the production stack in a dedicated workload account, or adjust the limit
to include other workloads sharing the account. AWS Budgets data is delayed,
so the CloudWatch hourly LLM estimated-cost alarm provides the faster signal.
