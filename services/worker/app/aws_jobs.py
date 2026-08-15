"""DynamoDB and SQS adapters for durable asynchronous inference jobs."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID, uuid4

from botocore.client import BaseClient
from botocore.exceptions import BotoCoreError, ClientError

from services.worker.app.jobs import (
    InvalidJobTransitionError,
    JobFailure,
    JobNotFoundError,
    JobOutcome,
    JobRecord,
    JobStatus,
    JobTask,
)

MESSAGE_VERSION = 2
MAX_PROMPT_LENGTH = 8000
TRACE_HEADER = "X-Amzn-Trace-Id"
MAX_TRACE_HEADER_LENGTH = 256


class DurableJobStoreError(RuntimeError):
    """A safe boundary for unavailable or invalid AWS persistence operations."""


class InvalidQueueMessageError(ValueError):
    """An SQS message failed strict validation and must be retried into the DLQ."""

    def __init__(self, message_id: str, receive_count: int, reason: str) -> None:
        super().__init__(reason)
        self.message_id = message_id
        self.receive_count = receive_count


@dataclass(frozen=True, slots=True)
class ReceivedJob:
    task: JobTask
    receipt_handle: str
    message_id: str
    receive_count: int


def serialize_task(task: JobTask) -> str:
    """Create a versioned payload; callers must never log the returned string."""

    _validate_task(task.job_id, task.prompt)
    trace_context = _validate_trace_context(task.trace_context)
    return json.dumps(
        {
            "version": MESSAGE_VERSION,
            "job_id": task.job_id,
            "prompt": task.prompt,
            "trace_context": trace_context,
        },
        separators=(",", ":"),
        ensure_ascii=False,
    )


def deserialize_task(body: str) -> JobTask:
    try:
        payload = json.loads(body)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ValueError("message body is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise TypeError("message body has an unsupported schema")
    version = payload.get("version")
    expected_fields = (
        {"version", "job_id", "prompt"}
        if version == 1
        else {"version", "job_id", "prompt", "trace_context"}
    )
    if set(payload) != expected_fields:
        raise ValueError("message body has an unsupported schema")
    if version not in {1, MESSAGE_VERSION}:
        raise ValueError("message version is unsupported")
    job_id, prompt = payload["job_id"], payload["prompt"]
    if not isinstance(job_id, str) or not isinstance(prompt, str):
        raise TypeError("message fields have invalid types")
    _validate_task(job_id, prompt)
    trace_context = (
        None if version == 1 else _validate_trace_context(payload["trace_context"])
    )
    return JobTask(job_id=job_id, prompt=prompt, trace_context=trace_context)


def _validate_task(job_id: str, prompt: str) -> None:
    try:
        UUID(job_id)
    except (ValueError, AttributeError) as exc:
        raise ValueError("job_id must be a UUID") from exc
    if not prompt.strip() or len(prompt) > MAX_PROMPT_LENGTH:
        raise ValueError("prompt length is invalid")


def _validate_trace_context(value: object) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {TRACE_HEADER}:
        raise ValueError("trace context has an unsupported schema")
    header = value.get(TRACE_HEADER)
    if (
        not isinstance(header, str)
        or not header
        or len(header) > MAX_TRACE_HEADER_LENGTH
        or "\r" in header
        or "\n" in header
    ):
        raise ValueError("trace context header is invalid")
    return {TRACE_HEADER: header}


class SQSJobQueue:
    def __init__(self, client: BaseClient, queue_url: str) -> None:
        if not queue_url:
            raise ValueError("queue_url must not be empty")
        self._client = client
        self._queue_url = queue_url

    def publish(self, task: JobTask) -> None:
        try:
            self._client.send_message(
                QueueUrl=self._queue_url,
                MessageBody=serialize_task(task),
            )
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError("Unable to publish the inference job.") from exc

    def receive(self, wait_time_seconds: int = 20) -> ReceivedJob | None:
        if not 0 <= wait_time_seconds <= 20:
            raise ValueError("wait_time_seconds must be between 0 and 20")
        try:
            response = self._client.receive_message(
                QueueUrl=self._queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=wait_time_seconds,
                AttributeNames=["ApproximateReceiveCount"],
            )
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError("Unable to receive inference jobs.") from exc
        messages = response.get("Messages", [])
        if not messages:
            return None
        message = messages[0]
        message_id = str(message.get("MessageId", "unknown"))
        try:
            receive_count = int(
                message.get("Attributes", {}).get("ApproximateReceiveCount", "1")
            )
            receipt_handle = message["ReceiptHandle"]
            task = deserialize_task(message["Body"])
        except (KeyError, TypeError, ValueError) as exc:
            count = receive_count if "receive_count" in locals() else 1
            raise InvalidQueueMessageError(message_id, count, str(exc)) from exc
        return ReceivedJob(task, receipt_handle, message_id, receive_count)

    def delete(self, receipt_handle: str) -> None:
        try:
            self._client.delete_message(
                QueueUrl=self._queue_url,
                ReceiptHandle=receipt_handle,
            )
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError(
                "Unable to acknowledge the inference job."
            ) from exc

    def check_ready(self) -> None:
        try:
            self._client.get_queue_attributes(
                QueueUrl=self._queue_url,
                AttributeNames=["QueueArn"],
            )
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError("The inference queue is unavailable.") from exc


class DynamoDBJobRepository:
    """Conditional state transitions make Standard SQS redelivery idempotent."""

    def __init__(
        self, client: BaseClient, table_name: str, ttl_seconds: int = 604800
    ) -> None:
        if not table_name:
            raise ValueError("table_name must not be empty")
        if ttl_seconds < 3600:
            raise ValueError("ttl_seconds must be at least one hour")
        self._client = client
        self._table_name = table_name
        self._ttl_seconds = ttl_seconds

    def create(self, job_id: str | None = None) -> JobRecord:
        now = datetime.now(UTC)
        record = JobRecord(job_id or str(uuid4()), JobStatus.PENDING, now, now)
        item = self._base_item(record)
        item["expires_at"] = {"N": str(int(now.timestamp()) + self._ttl_seconds)}
        try:
            self._client.put_item(
                TableName=self._table_name,
                Item=item,
                ConditionExpression="attribute_not_exists(job_id)",
            )
        except ClientError as exc:
            self._raise_client_error(exc, duplicate=True)
        except BotoCoreError as exc:
            raise DurableJobStoreError("Unable to create the inference job.") from exc
        return record

    def get(self, job_id: str) -> JobRecord:
        try:
            response = self._client.get_item(
                TableName=self._table_name,
                Key={"job_id": {"S": job_id}},
                ConsistentRead=True,
            )
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError("Unable to read the inference job.") from exc
        item = response.get("Item")
        if not item:
            raise JobNotFoundError(job_id)
        try:
            return self._record_from_item(item)
        except (KeyError, TypeError, ValueError) as exc:
            raise DurableJobStoreError("Stored inference job data is invalid.") from exc

    def mark_running(self, job_id: str) -> JobRecord:
        # RUNNING is accepted so a message can be reclaimed after a worker crash.
        return self._update(
            job_id,
            "SET #status = :running, updated_at = :updated",
            "#status IN (:pending, :running)",
            {
                ":pending": {"S": JobStatus.PENDING},
                ":running": {"S": JobStatus.RUNNING},
                ":updated": {"S": self._now()},
            },
        )

    def mark_succeeded(self, job_id: str, outcome: JobOutcome) -> JobRecord:
        values: dict[str, dict[str, str]] = {
            ":running": {"S": JobStatus.RUNNING},
            ":succeeded": {"S": JobStatus.SUCCEEDED},
            ":updated": {"S": self._now()},
            ":output": {"S": outcome.output},
            ":model": {"S": outcome.model_id},
        }
        assignments = [
            "#status = :succeeded",
            "updated_at = :updated",
            "#output = :output",
            "model_id = :model",
        ]
        for field, value in (
            ("input_tokens", outcome.input_tokens),
            ("output_tokens", outcome.output_tokens),
            ("estimated_cost", outcome.estimated_cost),
        ):
            if value is not None:
                key = f":{field}"
                values[key] = {"N": str(value)}
                assignments.append(f"{field} = {key}")
        return self._update(
            job_id,
            f"SET {', '.join(assignments)}",
            "#status = :running",
            values,
            names={"#status": "status", "#output": "output"},
        )

    def mark_failed(self, job_id: str, failure: JobFailure) -> JobRecord:
        return self._update(
            job_id,
            "SET #status = :failed, updated_at = :updated, error_code = :error",
            "#status IN (:pending, :running)",
            {
                ":pending": {"S": JobStatus.PENDING},
                ":running": {"S": JobStatus.RUNNING},
                ":failed": {"S": JobStatus.FAILED},
                ":updated": {"S": self._now()},
                ":error": {"S": failure.error_code},
            },
        )

    def check_ready(self) -> None:
        try:
            response = self._client.describe_table(TableName=self._table_name)
            if response.get("Table", {}).get("TableStatus") not in {
                "ACTIVE",
                "UPDATING",
            }:
                raise DurableJobStoreError("The job table is not active.")
        except DurableJobStoreError:
            raise
        except (BotoCoreError, ClientError) as exc:
            raise DurableJobStoreError("The job table is unavailable.") from exc

    def _update(
        self,
        job_id: str,
        update: str,
        condition: str,
        values: dict[str, dict[str, str]],
        names: dict[str, str] | None = None,
    ) -> JobRecord:
        try:
            response = self._client.update_item(
                TableName=self._table_name,
                Key={"job_id": {"S": job_id}},
                UpdateExpression=update,
                ConditionExpression=condition,
                ExpressionAttributeNames=names or {"#status": "status"},
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW",
            )
        except ClientError as exc:
            self._raise_client_error(exc)
        except BotoCoreError as exc:
            raise DurableJobStoreError("Unable to update the inference job.") from exc
        try:
            return self._record_from_item(response["Attributes"])
        except (KeyError, TypeError, ValueError) as exc:
            raise DurableJobStoreError(
                "Updated inference job data is invalid."
            ) from exc

    @staticmethod
    def _raise_client_error(exc: ClientError, duplicate: bool = False) -> None:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ConditionalCheckFailedException":
            message = (
                "job_id already exists" if duplicate else "invalid job state transition"
            )
            raise InvalidJobTransitionError(message) from exc
        raise DurableJobStoreError("The job store operation failed.") from exc

    @staticmethod
    def _base_item(record: JobRecord) -> dict[str, dict[str, str]]:
        return {
            "job_id": {"S": record.job_id},
            "status": {"S": record.status},
            "created_at": {"S": record.created_at.isoformat()},
            "updated_at": {"S": record.updated_at.isoformat()},
        }

    @staticmethod
    def _record_from_item(item: dict[str, dict[str, Any]]) -> JobRecord:
        number = lambda name: Decimal(item[name]["N"]) if name in item else None
        input_tokens = number("input_tokens")
        output_tokens = number("output_tokens")
        cost = number("estimated_cost")
        return JobRecord(
            job_id=item["job_id"]["S"],
            status=JobStatus(item["status"]["S"]),
            created_at=datetime.fromisoformat(item["created_at"]["S"]),
            updated_at=datetime.fromisoformat(item["updated_at"]["S"]),
            output=item.get("output", {}).get("S"),
            model_id=item.get("model_id", {}).get("S"),
            input_tokens=int(input_tokens) if input_tokens is not None else None,
            output_tokens=int(output_tokens) if output_tokens is not None else None,
            estimated_cost=float(cost) if cost is not None else None,
            error_code=item.get("error_code", {}).get("S"),
        )

    @staticmethod
    def _now() -> str:
        return datetime.now(UTC).isoformat()
