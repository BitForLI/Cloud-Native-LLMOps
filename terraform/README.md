# Terraform infrastructure

`modules/` contains reusable infrastructure components; `environments/`
composes them without copying resource definitions. The development root now
creates the foundation needed by later ECS work:

- one VPC with DNS enabled;
- public and private subnet tiers across two or three availability zones;
- an internet gateway and isolated route table per private subnet;
- configurable `none`, `single`, or `per_az` NAT topology;
- an S3 gateway endpoint on private routes;
- separate encrypted, scan-on-push, immutable ECR repositories for API and Worker;
- ECR lifecycle policies for untagged and excess images.
- a private, versioned, TLS-only S3 artifact bucket with lifecycle controls;
- an encrypted on-demand DynamoDB job table with TTL and point-in-time recovery;
- an encrypted long-poll SQS inference queue with bounded retries and a DLQ.
- separate least-privilege ECS execution, API, Worker, and GitHub deploy roles;
- GitHub OIDC federation restricted to exact immutable repository subjects.

The dev default uses one NAT gateway to control cost. Production should use
`per_az` for zone-independent egress. NAT gateways incur hourly and data
processing charges; `none` is useful only after all required private endpoints
exist.

## Validate locally

Install Terraform `1.10+`, then run:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/dev init -backend=false -lockfile=readonly
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test
```

Copy `terraform.tfvars.example` when values must differ. Do not commit real
credentials, `.tfstate`, or a populated backend file.

## Remote state

State infrastructure must exist before this stack. Copy
`backend.s3.tfbackend.example` outside version control, replace its bucket, and
initialize with:

```bash
terraform -chdir=terraform/environments/dev init \
  -backend-config=/secure/path/dev.s3.tfbackend
```

The S3 backend uses native lockfiles and encryption. AWS credentials come from
the standard provider chain locally and from GitHub OIDC in CI/CD; static access
keys do not belong in Terraform files.

## Durable job boundary

Infrastructure now exposes the SQS queue URL, DynamoDB table name, and S3
bucket name required by the distributed API/Worker adapters. This step creates
the managed services only; the application still uses its explicitly documented
process-local adapter until the following integration step. Failed SQS messages
remain in the DLQ for 14 days for inspection and controlled redrive.

## IAM boundaries

The API can submit SQS messages but cannot consume them; the Worker can consume
and delete messages but cannot submit them. Bedrock access is limited to the
configured model, data access is limited to this stack's S3/DynamoDB resources,
and GitHub can push only to the two service repositories, update the two ECS
services, and pass only the three platform roles.

The development trust uses GitHub's immutable subject for repository ID
`1320235086` under owner ID `218609705`, restricted to `master`. If an account
already has the account-wide GitHub OIDC provider, set
`github_oidc_provider_arn` instead of attempting to create a duplicate.
