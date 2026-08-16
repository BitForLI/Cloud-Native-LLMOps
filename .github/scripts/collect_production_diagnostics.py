from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

QUEUE_ATTRIBUTE_NAMES = [
    "ApproximateNumberOfMessages",
    "ApproximateNumberOfMessagesDelayed",
    "ApproximateNumberOfMessagesNotVisible",
    "CreatedTimestamp",
    "LastModifiedTimestamp",
    "RedrivePolicy",
]


def iso(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.astimezone(UTC).isoformat()
    return value


def collect_probe(
    report: dict[str, Any],
    name: str,
    function: Callable[[], Any],
) -> None:
    try:
        report["probes"][name] = {"ok": True, "data": function()}
    except (BotoCoreError, ClientError, KeyError, ValueError) as exc:
        error_code = type(exc).__name__
        if isinstance(exc, ClientError):
            error_code = exc.response.get("Error", {}).get("Code", error_code)
        report["probes"][name] = {"ok": False, "error_code": error_code}
        report["errors"].append(name)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect read-only production diagnostics.")
    parser.add_argument("--incident-id", required=True)
    parser.add_argument("--lookback-hours", required=True, type=int)
    parser.add_argument("--region", required=True)
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--api-service", required=True)
    parser.add_argument("--worker-service", required=True)
    parser.add_argument("--inference-queue-url", required=True)
    parser.add_argument("--dead-letter-queue-url", required=True)
    parser.add_argument("--alarm-name-prefix", required=True)
    parser.add_argument("--audit-trail-name", required=True)
    parser.add_argument("--backup-vault-name", required=True)
    parser.add_argument("--restore-testing-plan-arn", required=True)
    parser.add_argument("--codedeploy-application", required=True)
    parser.add_argument("--codedeploy-deployment-group", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{2,63}", args.incident_id) is None:
        parser.error("incident-id must be 3-64 alphanumeric or hyphen characters")
    if not 1 <= args.lookback_hours <= 168:
        parser.error("lookback-hours must be between 1 and 168")
    return args


def main() -> int:
    args = parse_args()
    now = datetime.now(UTC)
    since = now - timedelta(hours=args.lookback_hours)
    session = boto3.Session(region_name=args.region)
    ecs = session.client("ecs")
    cloudwatch = session.client("cloudwatch")
    sqs = session.client("sqs")
    cloudtrail = session.client("cloudtrail")
    backup = session.client("backup")
    codedeploy = session.client("codedeploy")

    report: dict[str, Any] = {
        "schema_version": 1,
        "incident_id": args.incident_id,
        "collected_at": now.isoformat(),
        "lookback_hours": args.lookback_hours,
        "region": args.region,
        "probes": {},
        "errors": [],
    }

    def ecs_services() -> dict[str, Any]:
        response = ecs.describe_services(
            cluster=args.cluster,
            services=[args.api_service, args.worker_service],
        )
        services = []
        for service in response.get("services", []):
            services.append(
                {
                    "serviceName": service.get("serviceName"),
                    "status": service.get("status"),
                    "desiredCount": service.get("desiredCount"),
                    "runningCount": service.get("runningCount"),
                    "pendingCount": service.get("pendingCount"),
                    "taskDefinition": service.get("taskDefinition"),
                    "deployments": [
                        {
                            key: deployment.get(key)
                            for key in (
                                "id",
                                "status",
                                "taskDefinition",
                                "desiredCount",
                                "pendingCount",
                                "runningCount",
                                "rolloutState",
                                "rolloutStateReason",
                            )
                        }
                        for deployment in service.get("deployments", [])
                    ],
                    "recentEvents": [
                        {
                            "createdAt": event.get("createdAt"),
                            "message": event.get("message"),
                        }
                        for event in service.get("events", [])[:10]
                    ],
                }
            )
        return {"services": services, "failures": response.get("failures", [])}

    def alarms() -> dict[str, Any]:
        response = cloudwatch.describe_alarms(AlarmNamePrefix=args.alarm_name_prefix)
        metric_alarms = [
            {
                "alarmName": alarm.get("AlarmName"),
                "stateValue": alarm.get("StateValue"),
                "stateReason": alarm.get("StateReason"),
                "stateUpdatedTimestamp": alarm.get("StateUpdatedTimestamp"),
                "actionsEnabled": alarm.get("ActionsEnabled"),
            }
            for alarm in response.get("MetricAlarms", [])
        ]
        return {"metricAlarms": metric_alarms}

    def queue(queue_url: str) -> dict[str, Any]:
        response = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=QUEUE_ATTRIBUTE_NAMES,
        )
        return response.get("Attributes", {})

    def trail() -> dict[str, Any]:
        response = cloudtrail.get_trail_status(Name=args.audit_trail_name)
        return {
            key: response.get(key)
            for key in (
                "IsLogging",
                "LatestDeliveryTime",
                "LatestDeliveryError",
                "LatestDigestDeliveryTime",
                "LatestDigestDeliveryError",
                "TimeLoggingStarted",
                "TimeLoggingStopped",
            )
        }

    def backup_health() -> dict[str, Any]:
        vault = backup.describe_backup_vault(BackupVaultName=args.backup_vault_name)
        jobs = backup.list_backup_jobs(
            ByBackupVaultName=args.backup_vault_name,
            ByCreatedAfter=since,
            MaxResults=100,
        )
        restores = backup.list_restore_jobs(
            ByCreatedAfter=since,
            ByRestoreTestingPlanArn=args.restore_testing_plan_arn,
            MaxResults=100,
        )
        return {
            "vault": {
                "backupVaultName": vault.get("BackupVaultName"),
                "numberOfRecoveryPoints": vault.get("NumberOfRecoveryPoints"),
                "locked": vault.get("Locked"),
                "minRetentionDays": vault.get("MinRetentionDays"),
                "maxRetentionDays": vault.get("MaxRetentionDays"),
            },
            "backupJobs": [
                {
                    key: job.get(key)
                    for key in (
                        "BackupJobId",
                        "State",
                        "StatusMessage",
                        "ResourceType",
                        "CreationDate",
                        "CompletionDate",
                    )
                }
                for job in jobs.get("BackupJobs", [])
            ],
            "restoreJobs": [
                {
                    key: job.get(key)
                    for key in (
                        "RestoreJobId",
                        "Status",
                        "StatusMessage",
                        "ResourceType",
                        "CreationDate",
                        "CompletionDate",
                        "ValidationStatus",
                        "ValidationStatusMessage",
                    )
                }
                for job in restores.get("RestoreJobs", [])
            ],
        }

    def deployment_group() -> dict[str, Any]:
        response = codedeploy.get_deployment_group(
            applicationName=args.codedeploy_application,
            deploymentGroupName=args.codedeploy_deployment_group,
        )["deploymentGroupInfo"]
        return {
            key: response.get(key)
            for key in (
                "applicationName",
                "deploymentGroupName",
                "deploymentConfigName",
                "lastSuccessfulDeployment",
                "lastAttemptedDeployment",
            )
        }

    collect_probe(report, "ecs_services", ecs_services)
    collect_probe(report, "cloudwatch_alarms", alarms)
    collect_probe(report, "inference_queue", lambda: queue(args.inference_queue_url))
    collect_probe(report, "dead_letter_queue", lambda: queue(args.dead_letter_queue_url))
    collect_probe(report, "cloudtrail", trail)
    collect_probe(report, "backup", backup_health)
    collect_probe(report, "codedeploy", deployment_group)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, default=iso, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Collected {len(report['probes'])} diagnostic probes; "
        f"failures={len(report['errors'])}"
    )
    return 0 if not report["errors"] else 1


if __name__ == "__main__":
    sys.exit(main())
