# ALB module

Creates the public application load balancer, API target group, security group,
and HTTP/optional HTTPS listeners. Production can enable a symmetric alternate
target group for CodeDeploy blue/green traffic shifting; both target groups
export ARNs, names, and CloudWatch dimension suffixes.
