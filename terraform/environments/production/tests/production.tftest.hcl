mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/mock-role"
      name = "mock-role"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:ap-southeast-2:123456789012:regional/webacl/mock/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-southeast-2:123456789012:log-group:aws-waf-logs-mock"
    }
  }
}

variables {
  availability_zones       = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  promotion_source_ecr_repository_arns = [
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/staging/api",
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/staging/worker",
  ]
  alb_certificate_arn        = "arn:aws:acm:ap-southeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  terraform_state_bucket_arn = "arn:aws:s3:::llmops-production-terraform-state"
  alarm_notification_emails  = ["platform@example.com"]
}

run "resilient_production_defaults" {
  command = plan

  assert {
    condition = (
      output.production_safety_profile.availability_zone_count == 3 &&
      output.production_safety_profile.nat_gateway_count == 3 &&
      output.production_safety_profile.api_desired_count >= 2 &&
      output.production_safety_profile.worker_desired_count >= 2 &&
      output.production_safety_profile.log_retention_days >= 365 &&
      output.production_safety_profile.data_deletion_protection &&
      output.production_safety_profile.load_balancer_protection &&
      output.production_safety_profile.api_alternate_target_group &&
      output.production_safety_profile.encrypted_api_auth &&
      output.production_safety_profile.trace_sample_ratio == 0.1 &&
      endswith(output.production_safety_profile.adot_collector_image, ":v0.48.0") &&
      output.production_safety_profile.autoscaling_bounds.api.min == 3 &&
      output.production_safety_profile.autoscaling_bounds.api.max == 12 &&
      output.production_safety_profile.autoscaling_bounds.worker.min == 2 &&
      output.production_safety_profile.autoscaling_bounds.worker.max == 30 &&
      output.production_safety_profile.worker_backlog_target == 2 &&
      output.production_safety_profile.waf_enabled &&
      startswith(output.production_safety_profile.waf_log_group, "aws-waf-logs-") &&
      output.production_safety_profile.waf_rate_limit == 5000 &&
      output.production_safety_profile.waf_alarm_name != null &&
      length(output.production_safety_profile.evaluation_alarm_names) == 3 &&
      output.production_safety_profile.llm_hourly_cost_alarm != null &&
      output.production_safety_profile.monthly_budget_name == "cloud-native-llmops-prod-monthly-cost" &&
      output.production_safety_profile.monthly_budget_limit_usd == 100 &&
      output.production_safety_profile.budget_alert_thresholds.actual_percent == 80 &&
      output.production_safety_profile.budget_alert_thresholds.forecast_percent == 100 &&
      output.production_safety_profile.audit_trail_name == "cloud-native-llmops-prod-management" &&
      output.production_safety_profile.audit_log_group == "/aws/cloudtrail/cloud-native-llmops-prod" &&
      output.production_safety_profile.audit_validation_enabled &&
      length(output.production_safety_profile.security_alarm_names) == 4 &&
      output.production_safety_profile.backup_vault_name == "cloud-native-llmops-prod-recovery" &&
      output.production_safety_profile.backup_plan_name == "cloud-native-llmops-prod-data-protection" &&
      output.production_safety_profile.backup_retention_days.daily == 35 &&
      output.production_safety_profile.backup_retention_days.weekly == 365 &&
      output.production_safety_profile.restore_testing_plan_name == "cloud_native_llmops_prod_monthly_restore" &&
      output.production_safety_profile.slo_availability_target == 99.9 &&
      output.production_safety_profile.slo_latency_compliance == 99 &&
      output.production_safety_profile.slo_window_hours == 168 &&
      output.production_safety_profile.slo_minimum_requests == 100 &&
      output.production_safety_profile.drift_alarm_names == ["cloud-native-llmops-prod-infrastructure-drift", "cloud-native-llmops-prod-infrastructure-drift-audit-absent"] &&
      output.production_safety_profile.drift_role_name == "cloud-native-llmops-prod-github-drift"
    )
    error_message = "Production must preserve multi-AZ capacity, retention, deletion protection, and two target groups."
  }

  assert {
    condition = (
      output.production_safety_profile.deployment_config == "CodeDeployDefault.ECSCanary10Percent5Minutes" &&
      output.production_safety_profile.blue_termination_wait >= 5
    )
    error_message = "Production must keep a 10 percent canary and a blue bake window."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.infrastructure_drift.namespace == "CloudNativeLLMOps" &&
      aws_cloudwatch_metric_alarm.infrastructure_drift.metric_name == "InfrastructureDriftDetected" &&
      aws_cloudwatch_metric_alarm.infrastructure_drift.period == 300 &&
      aws_cloudwatch_metric_alarm.infrastructure_drift.treat_missing_data == "ignore" &&
      length(aws_cloudwatch_metric_alarm.infrastructure_drift.alarm_actions) == 1 &&
      length(aws_cloudwatch_metric_alarm.infrastructure_drift.ok_actions) == 1 &&
      aws_cloudwatch_metric_alarm.infrastructure_drift_absent.metric_name == "InfrastructureDriftAuditHeartbeat" &&
      aws_cloudwatch_metric_alarm.infrastructure_drift_absent.period == 21600 &&
      aws_cloudwatch_metric_alarm.infrastructure_drift_absent.evaluation_periods == 5 &&
      aws_cloudwatch_metric_alarm.infrastructure_drift_absent.datapoints_to_alarm == 5 &&
      aws_cloudwatch_metric_alarm.infrastructure_drift_absent.treat_missing_data == "breaching"
    )
    error_message = "Daily drift and missing audits must alarm through the encrypted production topic."
  }

  assert {
    condition     = length(output.deployment_alarm_names.api) == 7
    error_message = "CodeDeploy must monitor both blue and green ALB error and latency signals."
  }

  assert {
    condition = toset(keys(output.deployment_github_variables)) == toset([
      "API_ECS_SERVICE",
      "API_AUTH_SECRET_ID",
      "API_URL",
      "AWS_ACCOUNT_ID",
      "AWS_DEPLOY_ROLE_ARN",
      "AWS_EVALUATION_ROLE_ARN",
      "AWS_REGION",
      "ARTIFACT_BUCKET",
      "CODEDEPLOY_APPLICATION",
      "CODEDEPLOY_DEPLOYMENT_GROUP",
      "ECS_CLUSTER",
      "PRODUCTION_API_ECR_REPOSITORY",
      "PRODUCTION_WORKER_ECR_REPOSITORY",
      "WORKER_ECS_SERVICE",
      "ALB_LOAD_BALANCER_SUFFIX",
      "ALB_TARGET_GROUP_SUFFIX",
      "SLO_AVAILABILITY_TARGET_PERCENT",
      "SLO_LATENCY_TARGET_MS",
      "SLO_LATENCY_COMPLIANCE_PERCENT",
      "SLO_WINDOW_HOURS",
      "SLO_MINIMUM_REQUESTS",
    ])
    error_message = "Production must expose the complete non-secret release configuration."
  }

  assert {
    condition = toset(keys(output.operations_github_variables)) == toset([
      "ALARM_NAME_PREFIX",
      "API_ECS_SERVICE",
      "AUDIT_TRAIL_NAME",
      "AWS_ACCOUNT_ID",
      "AWS_OPERATIONS_ROLE_ARN",
      "AWS_REGION",
      "BACKUP_VAULT_NAME",
      "CODEDEPLOY_APPLICATION",
      "CODEDEPLOY_DEPLOYMENT_GROUP",
      "DEAD_LETTER_QUEUE_URL",
      "ECS_CLUSTER",
      "INFERENCE_QUEUE_URL",
      "RESTORE_TESTING_PLAN_ARN",
      "WORKER_ECS_SERVICE",
    ])
    error_message = "Production must expose the complete non-secret incident diagnostics configuration."
  }

  assert {
    condition = toset(keys(output.drift_github_variables)) == toset([
      "AWS_ACCOUNT_ID",
      "AWS_DRIFT_ROLE_ARN",
      "AWS_REGION",
      "TF_BACKEND_BUCKET",
      "TF_BACKEND_KEY",
    ])
    error_message = "Production must expose the complete non-secret drift-audit configuration."
  }
}

run "drift_role_reads_state_and_configuration_without_sensitive_data" {
  command = apply

  module { source = "../../modules/drift_detection" }

  variables {
    name                        = "llmops-production"
    github_oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_oidc_subjects        = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-drift"]
    terraform_state_bucket_arn  = "arn:aws:s3:::llmops-production-terraform-state"
    terraform_state_key         = "cloud-native-llmops/production/terraform.tfstate"
    terraform_state_kms_key_arn = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    managed_s3_bucket_arns      = ["arn:aws:s3:::llmops-production-artifacts", "arn:aws:s3:::llmops-production-audit"]
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.github_drift.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-drift"] &&
      one([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Sid == "ReadExactTerraformStateObject"]).Resource == ["arn:aws:s3:::llmops-production-terraform-state/cloud-native-llmops/production/terraform.tfstate"] &&
      one([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Sid == "DecryptExactTerraformStateKey"]).Resource == ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"] &&
      one([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Sid == "PublishBinaryDriftSignal"]).Condition.StringEquals["cloudwatch:namespace"] == ["CloudNativeLLMOps"] &&
      one([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Sid == "ReadManagedBucketConfiguration"]).Resource == ["arn:aws:s3:::llmops-production-artifacts", "arn:aws:s3:::llmops-production-audit"] &&
      contains(one([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Sid == "DenySensitiveDataReads"]).Action, "secretsmanager:GetSecretValue") &&
      length([for statement in jsondecode(local.audit_policy).Statement : statement if statement.Effect == "Allow" && contains(statement.Action, "secretsmanager:GetSecretValue")]) == 0
    )
    error_message = "Drift audit must read one state object and control-plane metadata without application data."
  }

  assert {
    condition = length([
      for action in flatten([
        for statement in jsondecode(local.audit_policy).Statement : statement.Action
        if statement.Effect == "Allow"
      ]) : action
      if action != "cloudwatch:PutMetricData" && can(regex(":(Create|Put|Update|Delete|Register|Deregister|Start|Stop|Restore|Pass|Tag|Untag|Set)", action))
    ]) == 0
    error_message = "The drift role must not contain infrastructure mutation actions."
  }
}

run "release_role_can_only_read_slo_metrics" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.production_error_budget.policy).Statement[0].Action == ["cloudwatch:GetMetricData"] &&
      jsondecode(aws_iam_role_policy.production_error_budget.policy).Statement[0].Resource == "*" &&
      !strcontains(aws_iam_role_policy.production_error_budget.policy, "PutMetricData") &&
      !strcontains(aws_iam_role_policy.production_error_budget.policy, "DeleteAlarms")
    )
    error_message = "The release role must have read-only access to the exact SLO metric API."
  }
}

run "operations_role_is_read_only_and_incident_scoped" {
  command = apply

  module { source = "../../modules/operations" }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "ap-southeast-2" }
  }

  variables {
    name                     = "llmops-production"
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_oidc_subjects     = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-operations"]
    ecs_cluster_name         = "llmops-production"
    ecs_service_names        = ["llmops-production-api", "llmops-production-worker"]
    queue_arns = [
      "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference",
      "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference-dlq",
    ]
    alarm_name_prefix               = "llmops-production"
    cloudtrail_trail_name           = "llmops-production-management"
    backup_vault_arn                = "arn:aws:backup:ap-southeast-2:123456789012:backup-vault:llmops-production-recovery"
    codedeploy_deployment_group_arn = "arn:aws:codedeploy:ap-southeast-2:123456789012:deploymentgroup:llmops-production/llmops-production-api"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.github_operations.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" &&
      jsondecode(aws_iam_role.github_operations.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.github_operations.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-operations"] &&
      aws_iam_role.github_operations.max_session_duration == 3600
    )
    error_message = "Diagnostics must trust only the protected production-operations GitHub environment."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DescribeWorkloadServices"]).Resource == [
        "arn:aws:ecs:ap-southeast-2:123456789012:service/llmops-production/llmops-production-api",
        "arn:aws:ecs:ap-southeast-2:123456789012:service/llmops-production/llmops-production-worker",
      ] &&
      one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "ReadQueuePressure"]).Resource == [
        "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference",
        "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference-dlq",
      ] &&
      one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "ReadAuditDeliveryHealth"]).Resource == ["arn:aws:cloudtrail:ap-southeast-2:123456789012:trail/llmops-production-management"] &&
      one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "ReadRecoveryHealth"]).Resource == ["arn:aws:backup:ap-southeast-2:123456789012:backup-vault:llmops-production-recovery"]
    )
    error_message = "Diagnostics reads must be scoped to the exact workload services, queues, trail, and recovery vault."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DenyMutationAndSensitiveReads"]).Effect == "Deny" &&
      contains(one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DenyMutationAndSensitiveReads"]).Action, "secretsmanager:GetSecretValue") &&
      contains(one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DenyMutationAndSensitiveReads"]).Action, "ecs:UpdateService") &&
      contains(one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DenyMutationAndSensitiveReads"]).Action, "codedeploy:CreateDeployment") &&
      contains(one([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Sid == "DenyMutationAndSensitiveReads"]).Action, "iam:PassRole") &&
      length([for statement in jsondecode(local.diagnostics_policy).Statement : statement if statement.Effect == "Allow" && contains(statement.Action, "secretsmanager:GetSecretValue")]) == 0
    )
    error_message = "The operations identity must be unable to read secrets, deploy, mutate queues, or start recovery jobs."
  }
}

run "backups_are_locked_scoped_and_restore_tested" {
  command = apply

  module { source = "../../modules/backup" }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_resource {
    target = aws_kms_key.backup
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  override_resource {
    target = aws_backup_vault.this
    values = {
      arn  = "arn:aws:backup:ap-southeast-2:123456789012:backup-vault:llmops-production-recovery"
      name = "llmops-production-recovery"
    }
  }

  variables {
    name                = "llmops-production"
    artifact_bucket_arn = "arn:aws:s3:::llmops-production-artifacts"
    job_table_arn       = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-production-jobs"
  }

  assert {
    condition = (
      aws_kms_key.backup.enable_key_rotation &&
      aws_kms_key.backup.deletion_window_in_days == 30 &&
      aws_backup_vault.this.kms_key_arn == aws_kms_key.backup.arn &&
      !aws_backup_vault.this.force_destroy &&
      aws_backup_vault_lock_configuration.this.min_retention_days == 35 &&
      aws_backup_vault_lock_configuration.this.max_retention_days == 3650 &&
      aws_backup_vault_lock_configuration.this.changeable_for_days == null
    )
    error_message = "Recovery points must use a rotating customer key and a governance-mode retention lock."
  }

  assert {
    condition = (
      length(aws_backup_plan.this.rule) == 2 &&
      one([for rule in aws_backup_plan.this.rule : rule if rule.rule_name == "daily"]).schedule == "cron(0 5 ? * * *)" &&
      one([for rule in aws_backup_plan.this.rule : rule if rule.rule_name == "daily"]).lifecycle[0].delete_after == 35 &&
      one([for rule in aws_backup_plan.this.rule : rule if rule.rule_name == "weekly"]).schedule == "cron(0 6 ? * SUN *)" &&
      one([for rule in aws_backup_plan.this.rule : rule if rule.rule_name == "weekly"]).lifecycle[0].delete_after == 365 &&
      alltrue([for rule in aws_backup_plan.this.rule : rule.start_window == 60 && rule.completion_window == 720])
    )
    error_message = "The plan must retain bounded daily and weekly recovery points with explicit execution windows."
  }

  assert {
    condition = (
      aws_backup_selection.data.iam_role_arn == aws_iam_role.backup.arn &&
      toset(aws_backup_selection.data.resources) == toset([
        "arn:aws:s3:::llmops-production-artifacts",
        "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-production-jobs",
      ]) &&
      toset([for attachment in aws_iam_role_policy_attachment.backup : attachment.policy_arn]) == toset([
        "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
        "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup",
      ]) &&
      toset([for attachment in aws_iam_role_policy_attachment.restore : attachment.policy_arn]) == toset([
        "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
        "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore",
      ]) &&
      jsondecode(aws_iam_role.backup.assume_role_policy).Statement[0].Principal.Service == "backup.amazonaws.com" &&
      jsondecode(aws_iam_role.backup.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012" &&
      aws_iam_role.restore.assume_role_policy == aws_iam_role.backup.assume_role_policy &&
      !strcontains(join(" ", concat(values(local.backup_policy_arns), values(local.restore_policy_arns))), "ECR") &&
      !strcontains(join(" ", concat(values(local.backup_policy_arns), values(local.restore_policy_arns))), "CodeDeploy")
    )
    error_message = "Backup and restore roles must remain separate from deployment and target only explicit protected resources."
  }

  assert {
    condition = (
      aws_backup_restore_testing_plan.this[0].schedule_expression == "cron(0 8 1 * ? *)" &&
      aws_backup_restore_testing_plan.this[0].recovery_point_selection[0].algorithm == "LATEST_WITHIN_WINDOW" &&
      aws_backup_restore_testing_plan.this[0].recovery_point_selection[0].include_vaults == toset([aws_backup_vault.this.arn]) &&
      aws_backup_restore_testing_plan.this[0].recovery_point_selection[0].recovery_point_types == toset(["SNAPSHOT"]) &&
      aws_backup_restore_testing_plan.this[0].recovery_point_selection[0].selection_window_days == 35 &&
      length(aws_backup_restore_testing_selection.data) == 2 &&
      aws_backup_restore_testing_selection.data["s3"].protected_resource_type == "S3" &&
      aws_backup_restore_testing_selection.data["s3"].protected_resource_arns == toset(["arn:aws:s3:::llmops-production-artifacts"]) &&
      aws_backup_restore_testing_selection.data["dynamodb"].protected_resource_type == "DynamoDB" &&
      aws_backup_restore_testing_selection.data["dynamodb"].protected_resource_arns == toset(["arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-production-jobs"]) &&
      alltrue([for selection in aws_backup_restore_testing_selection.data : selection.validation_window_hours == 1 && selection.iam_role_arn == aws_iam_role.restore.arn])
    )
    error_message = "Monthly restore tests must exercise the latest S3 and DynamoDB snapshots through the isolated restore role."
  }
}

run "audit_trail_is_encrypted_validated_and_detected" {
  command = apply

  module { source = "../../modules/audit" }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_resource {
    target = aws_kms_key.audit
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  variables {
    name                   = "llmops-production"
    aws_region             = "ap-southeast-2"
    log_retention_days     = 365
    archive_retention_days = 2557
    alarm_topic_arn        = "arn:aws:sns:ap-southeast-2:123456789012:llmops-production-alarms"
  }

  assert {
    condition = (
      aws_cloudtrail.management.enable_logging &&
      aws_cloudtrail.management.enable_log_file_validation &&
      aws_cloudtrail.management.include_global_service_events &&
      aws_cloudtrail.management.is_multi_region_trail &&
      one(aws_cloudtrail.management.event_selector).include_management_events &&
      one(aws_cloudtrail.management.event_selector).read_write_type == "All"
    )
    error_message = "CloudTrail must continuously record all management events across enabled Regions and global services."
  }

  assert {
    condition = (
      aws_kms_key.audit.enable_key_rotation &&
      strcontains(aws_kms_key.audit.policy, "cloudtrail.amazonaws.com") &&
      strcontains(aws_kms_key.audit.policy, "logs.ap-southeast-2.amazonaws.com") &&
      strcontains(aws_kms_key.audit.policy, "aws:SourceArn") &&
      strcontains(aws_kms_key.audit.policy, "AllowCloudTrailBucketKeyDecryption") &&
      one(aws_s3_bucket_versioning.audit.versioning_configuration).status == "Enabled" &&
      aws_s3_bucket_public_access_block.audit.restrict_public_buckets &&
      one(aws_s3_bucket_lifecycle_configuration.audit.rule).expiration[0].days == 2557
    )
    error_message = "Audit archives must be encrypted, versioned, private, and retained for the configured period."
  }

  assert {
    condition = (
      strcontains(aws_s3_bucket_policy.audit.policy, "DenyInsecureTransport") &&
      strcontains(aws_s3_bucket_policy.audit.policy, "bucket-owner-full-control") &&
      strcontains(aws_s3_bucket_policy.audit.policy, "arn:aws:cloudtrail:ap-southeast-2:123456789012:trail/llmops-production-management") &&
      strcontains(aws_iam_role_policy.cloudtrail_logs.policy, "logs:CreateLogStream") &&
      strcontains(aws_iam_role_policy.cloudtrail_logs.policy, "logs:PutLogEvents")
    )
    error_message = "CloudTrail delivery permissions must be transport-safe and scoped to the exact trail and log streams."
  }

  assert {
    condition = (
      length(aws_cloudwatch_log_metric_filter.security) == 4 &&
      length(aws_cloudwatch_metric_alarm.security) == 4 &&
      alltrue([for alarm in aws_cloudwatch_metric_alarm.security : alarm.alarm_actions == toset(["arn:aws:sns:ap-southeast-2:123456789012:llmops-production-alarms"])]) &&
      toset(keys(aws_cloudwatch_metric_alarm.security)) == toset(["unauthorized", "root_activity", "iam_change", "trail_change"])
    )
    error_message = "Audit telemetry must alert on denied calls, root use, IAM writes, and trail tampering."
  }
}

run "monthly_budget_warns_before_and_at_forecasted_limit" {
  command = apply

  module { source = "../../modules/cost_control" }

  variables {
    name                     = "llmops-production"
    monthly_budget_limit_usd = 100
    notification_topic_arn   = "arn:aws:sns:ap-southeast-2:123456789012:llmops-production-alarms"
  }

  assert {
    condition = (
      aws_budgets_budget.monthly.budget_type == "COST" &&
      aws_budgets_budget.monthly.time_unit == "MONTHLY" &&
      aws_budgets_budget.monthly.limit_unit == "USD" &&
      tonumber(aws_budgets_budget.monthly.limit_amount) == 100 &&
      length(aws_budgets_budget.monthly.notification) == 2 &&
      one([for notification in aws_budgets_budget.monthly.notification : notification if notification.notification_type == "ACTUAL"]).threshold == 80 &&
      one([for notification in aws_budgets_budget.monthly.notification : notification if notification.notification_type == "FORECASTED"]).threshold == 100 &&
      alltrue([for notification in aws_budgets_budget.monthly.notification : notification.subscriber_sns_topic_arns == toset(["arn:aws:sns:ap-southeast-2:123456789012:llmops-production-alarms"])])
    )
    error_message = "The monthly budget must alert on actual and forecast spend through the encrypted operations topic."
  }
}

run "codedeploy_canary_rolls_back_on_alarms" {
  command = apply

  module { source = "../../modules/codedeploy" }

  variables {
    name                     = "llmops-production"
    ecs_cluster_name         = "llmops-production"
    ecs_service_name         = "llmops-production-api"
    production_listener_arns = ["arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:listener/app/prod/id/listener"]
    target_group_names       = ["prod-blue", "prod-green"]
    alarm_names              = ["prod-api-errors", "prod-api-latency"]
  }

  assert {
    condition = (
      aws_codedeploy_app.api.compute_platform == "ECS" &&
      aws_codedeploy_deployment_group.api.deployment_config_name == "CodeDeployDefault.ECSCanary10Percent5Minutes" &&
      one(aws_codedeploy_deployment_group.api.deployment_style).deployment_type == "BLUE_GREEN" &&
      one(aws_codedeploy_deployment_group.api.deployment_style).deployment_option == "WITH_TRAFFIC_CONTROL"
    )
    error_message = "The API deployment group must perform a 10 percent ECS blue/green canary."
  }

  assert {
    condition = (
      one(aws_codedeploy_deployment_group.api.alarm_configuration).enabled &&
      !one(aws_codedeploy_deployment_group.api.alarm_configuration).ignore_poll_alarm_failure &&
      toset(one(aws_codedeploy_deployment_group.api.alarm_configuration).alarms) == toset(["prod-api-errors", "prod-api-latency"])
    )
    error_message = "CodeDeploy must fail closed when release alarms cannot be polled or enter ALARM."
  }

  assert {
    condition = (
      one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).enabled &&
      contains(one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).events, "DEPLOYMENT_FAILURE") &&
      contains(one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).events, "DEPLOYMENT_STOP_ON_ALARM")
    )
    error_message = "Failed or alarmed deployments must automatically roll back."
  }

  assert {
    condition = (
      length(one(one(aws_codedeploy_deployment_group.api.load_balancer_info).target_group_pair_info).target_group) == 2 &&
      one(one(aws_codedeploy_deployment_group.api.blue_green_deployment_config).terminate_blue_instances_on_deployment_success).termination_wait_time_in_minutes >= 5
    )
    error_message = "Blue/green requires two target groups and a post-shift bake window."
  }
}

run "production_role_cannot_bypass_artifact_or_api_release" {
  command = apply

  module { source = "../../modules/iam" }

  variables {
    name                      = "llmops-production"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/production/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/production/worker"
    promotion_source_ecr_repository_arns = [
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/api",
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/worker",
    ]
    promotion_only                   = true
    supply_chain_signing_enabled     = true
    github_api_update_enabled        = false
    artifact_bucket_arn              = "arn:aws:s3:::llmops-production-artifacts"
    job_table_arn                    = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-production-jobs"
    inference_queue_arn              = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference"
    bedrock_model_ids                = ["test-model"]
    secret_arns                      = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-production/api-auth-token-AbCdEf"]
    secret_kms_key_arns              = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_verification_secret_arns  = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-production/api-auth-token-AbCdEf"]
    github_verification_kms_key_arns = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_oidc_provider_arn         = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_oidc_subjects             = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production"]
    github_evaluation_oidc_subjects  = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-monitoring"]
  }

  assert {
    condition = (
      contains(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "PushServiceImages"]).Action, "ecr:UploadLayerPart") &&
      contains(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadPromotionSources"]).Action, "ecr:GetDownloadUrlForLayer") &&
      length(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "UpdateDeploymentServices"]).Resource) == 1 &&
      endswith(one(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "UpdateDeploymentServices"]).Resource), "-worker") &&
      length([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadReleaseVerificationSecret"]) == 1 &&
      length([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "DecryptReleaseVerificationSecret"]) == 1
    )
    error_message = "Production automation may copy signed manifests, write scoped signatures, and directly update only the Worker service."
  }

  assert {
    condition = (
      length([for statement in jsondecode(local.github_evaluation_policy).Statement : statement if statement.Sid == "PublishEvaluationMetrics" && statement.Condition.StringEquals["cloudwatch:namespace"] == ["CloudNativeLLMOps"]]) == 1 &&
      one([for statement in jsondecode(local.github_evaluation_policy).Statement : statement if statement.Sid == "WriteImmutableEvaluationEvidence"]).Resource == ["arn:aws:s3:::llmops-production-artifacts/evaluations/*"] &&
      one([for statement in jsondecode(local.github_evaluation_policy).Statement : statement if statement.Sid == "WriteImmutableEvaluationEvidence"]).Condition.StringEquals["s3:if-none-match"] == ["*"] &&
      length([for statement in jsondecode(local.github_evaluation_policy).Statement : statement if startswith(statement.Sid, "Read") || startswith(statement.Sid, "Decrypt")]) == 2 &&
      length([for statement in jsondecode(local.github_evaluation_policy).Statement : statement if can(regex("^(ecr|ecs|codedeploy|iam):", join(" ", statement.Action)))]) == 0
    )
    error_message = "Continuous evaluation must have evidence, metric, and token access without deployment permissions."
  }
}

run "rejects_underprovisioned_production" {
  command = plan
  variables {
    api_desired_count    = 1
    worker_desired_count = 1
  }
  expect_failures = [var.api_desired_count, var.worker_desired_count]
}

run "rejects_unprotected_production_identity" {
  command = plan
  variables {
    github_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_oidc_subjects]
}

run "rejects_unprotected_evaluation_identity" {
  command = plan
  variables {
    github_evaluation_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_evaluation_oidc_subjects]
}

run "rejects_unprotected_operations_identity" {
  command = plan
  variables {
    github_operations_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_operations_oidc_subjects]
}

run "rejects_unprotected_drift_identity" {
  command = plan
  variables {
    github_drift_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_drift_oidc_subjects]
}

run "rejects_missing_alarm_recipient" {
  command = plan
  variables { alarm_notification_emails = [] }
  expect_failures = [var.alarm_notification_emails]
}

run "rejects_hourly_cost_guardrail_above_monthly_budget" {
  command = plan
  variables {
    monthly_budget_limit_usd            = 100
    alarm_llm_hourly_cost_threshold_usd = 101
  }
  expect_failures = [var.alarm_llm_hourly_cost_threshold_usd]
}

run "rejects_unrecoverable_production_configuration" {
  command = plan
  variables {
    backup_weekly_retention_days   = 364
    backup_restore_testing_enabled = false
  }
  expect_failures = [var.backup_weekly_retention_days, var.backup_restore_testing_enabled]
}
