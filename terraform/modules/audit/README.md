# Audit module

Creates one multi-Region CloudTrail for management events, including global
services such as IAM. Logs are encrypted with a rotating customer KMS key,
archived in a private versioned S3 bucket, and signed with CloudTrail log-file
validation digests.

CloudWatch Logs metric filters alert on unauthorized API calls, root identity
use, IAM writes, and attempts to change or stop the trail. The trail records
control-plane metadata; it intentionally does not enable broad Bedrock or S3
data events that could increase cost or capture sensitive application inputs.
