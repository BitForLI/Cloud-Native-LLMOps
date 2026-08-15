# ECS service autoscaling

Registers the API and Worker ECS services with Application Auto Scaling. The
API has independent CPU and memory target-tracking policies: either signal may
scale out, while scale-in occurs only when both policies permit it.

The Worker follows queue pressure rather than CPU. Its custom target metric is
`ApproximateNumberOfMessagesVisible / RunningTaskCount`, using the SQS metric
and ECS Container Insights. This keeps concurrency proportional to pending
inference jobs without publishing a separate custom metric.

Minimum capacity preserves each environment's availability baseline. Maximum
capacity is a hard cost and Bedrock-concurrency guardrail. Scale-out uses a
short cooldown; scale-in is deliberately slower to reduce task churn.
