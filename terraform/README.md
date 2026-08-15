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
