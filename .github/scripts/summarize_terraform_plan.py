"""Create a value-free, policy-classified Terraform drift report."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ALLOWED_STATUSES = {"clean", "drift", "error"}
SENSITIVE_KEYS = {
    "after",
    "after_sensitive",
    "before",
    "before_sensitive",
    "configuration",
    "planned_values",
    "prior_state",
}


def classify(address: str, resource_type: str, actions: list[str]) -> list[str]:
    findings: list[str] = []
    action_set = set(actions)
    if "delete" in action_set:
        findings.append("destructive_change")
    if {"create", "delete"}.issubset(action_set):
        findings.append("resource_replacement")
    if resource_type.startswith("aws_iam_"):
        findings.append("identity_boundary_change")
    if resource_type.startswith(
        ("aws_security_group", "aws_lb", "aws_wafv2", "aws_network_acl")
    ):
        findings.append("network_boundary_change")
    if resource_type.startswith(
        ("aws_s3_", "aws_dynamodb_", "aws_backup_", "aws_kms_")
    ):
        findings.append("data_protection_change")
    if address.startswith("module.secrets") or resource_type.startswith(
        "aws_secretsmanager_"
    ):
        findings.append("secret_control_change")
    return sorted(set(findings))


def summarize(plan: dict[str, Any], status: str, revision: str) -> dict[str, Any]:
    if status not in ALLOWED_STATUSES:
        raise ValueError(f"unsupported plan status: {status}")
    changes = []
    action_counts: Counter[str] = Counter()
    finding_counts: Counter[str] = Counter()
    output_changes = []

    for resource in plan.get("resource_changes", []):
        actions = list(resource.get("change", {}).get("actions", []))
        if not actions or actions == ["no-op"] or actions == ["read"]:
            continue
        address = str(resource.get("address", "unknown"))
        resource_type = str(resource.get("type", "unknown"))
        findings = classify(address, resource_type, actions)
        action_counts.update(actions)
        finding_counts.update(findings)
        changes.append(
            {
                "address": address,
                "actions": actions,
                "mode": resource.get("mode", "managed"),
                "provider": resource.get("provider_name", "unknown"),
                "type": resource_type,
                "policy_findings": findings,
            }
        )

    changes.sort(key=lambda item: item["address"])
    for name, output in plan.get("output_changes", {}).items():
        actions = list(output.get("actions", []))
        if actions and actions != ["no-op"] and actions != ["read"]:
            action_counts.update(actions)
            output_changes.append({"name": name, "actions": actions})
    output_changes.sort(key=lambda item: item["name"])
    has_changes = bool(changes or output_changes)
    if status == "clean" and has_changes:
        raise ValueError("clean status cannot contain planned changes")
    if status == "drift" and not has_changes:
        raise ValueError("drift status must contain at least one planned change")

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "revision": revision,
        "plan_status": status,
        "passed": status == "clean" and not changes,
        "summary": {
            "changed_resources": len(changes),
            "changed_outputs": len(output_changes),
            "actions": dict(sorted(action_counts.items())),
            "policy_findings": dict(sorted(finding_counts.items())),
        },
        "changes": changes,
        "output_changes": output_changes,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--status", required=True, choices=sorted(ALLOWED_STATUSES))
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        raise ValueError("revision must be a full 40-character commit SHA")
    if args.status == "error":
        plan: dict[str, Any] = {}
    else:
        if args.plan is None:
            raise ValueError("--plan is required for clean and drift statuses")
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
    report = summarize(plan, args.status, args.revision)
    serialized = json.dumps(report, indent=2, sort_keys=True, allow_nan=False)
    if any(key in report for key in SENSITIVE_KEYS):
        raise ValueError("report contains a forbidden Terraform value section")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized + "\n", encoding="utf-8")
    print(
        f"Terraform drift status={report['plan_status']} "
        f"changed_resources={report['summary']['changed_resources']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
