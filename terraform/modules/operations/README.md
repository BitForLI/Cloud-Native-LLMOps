# Operations diagnostics module

Creates one GitHub OIDC role trusted only by the exact protected
`production-operations` environment. Its allow statements read the two ECS
services, workload alarm prefix, inference/DLQ queues, management trail,
recovery vault/jobs, and CodeDeploy group.

An explicit deny prevents secret retrieval, remote shell execution, deployment,
queue mutation, backup/restore starts or deletion, and `iam:PassRole`, even if a
broader policy is attached later. This role is for evidence collection only;
operators execute rollback or recovery through separately approved procedures.
