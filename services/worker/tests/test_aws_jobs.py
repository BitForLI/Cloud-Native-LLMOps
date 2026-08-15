import json
from datetime import UTC, datetime

import pytest
from botocore.exceptions import ClientError

from services.worker.app.aws_jobs import (
    DurableJobStoreError,
    DynamoDBJobRepository,
    InvalidQueueMessageError,
    SQSJobQueue,
    deserialize_task,
    serialize_task,
)
from services.worker.app.jobs import (
    InvalidJobTransitionError,
    JobOutcome,
    JobStatus,
    JobTask,
)

JOB_ID = "0198ab9a-b91c-7000-8000-000000000001"


def item(status="pending", **extra):
    now = datetime.now(UTC).isoformat()
    value = {
        "job_id": {"S": JOB_ID},
        "status": {"S": status},
        "created_at": {"S": now},
        "updated_at": {"S": now},
    }
    value.update(extra)
    return value


class FakeSQS:
    def __init__(self, response=None, error=None):
        self.response = response or {}
        self.error = error
        self.calls = []

    def __getattr__(self, name):
        def call(**kwargs):
            self.calls.append((name, kwargs))
            if self.error:
                raise self.error
            return self.response

        return call


class FakeDynamo:
    def __init__(self):
        self.calls = []
        self.responses = {}
        self.error = None

    def __getattr__(self, name):
        def call(**kwargs):
            self.calls.append((name, kwargs))
            if self.error:
                raise self.error
            return self.responses.get(name, {})

        return call


def conditional_error():
    return ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException", "Message": "secret"}},
        "UpdateItem",
    )


def test_task_serialization_is_versioned_strict_and_round_trips_unicode():
    task = JobTask(JOB_ID, "  私密 prompt  ")

    body = serialize_task(task)

    assert deserialize_task(body) == task
    assert json.loads(body)["version"] == 2
    with pytest.raises(ValueError, match="schema"):
        deserialize_task(
            json.dumps({"version": 1, "job_id": JOB_ID, "prompt": "x", "extra": 1})
        )


def test_task_serialization_carries_only_bounded_xray_context_and_reads_v1():
    carrier = {"X-Amzn-Trace-Id": "Root=1-12345678-123456789012345678901234;Sampled=1"}
    task = JobTask(JOB_ID, "private", carrier)

    assert deserialize_task(serialize_task(task)) == task
    assert deserialize_task(
        json.dumps({"version": 1, "job_id": JOB_ID, "prompt": "legacy"})
    ) == JobTask(JOB_ID, "legacy")

    with pytest.raises(ValueError, match="trace context"):
        serialize_task(JobTask(JOB_ID, "private", {"Authorization": "secret"}))
    with pytest.raises(ValueError, match="trace context"):
        serialize_task(JobTask(JOB_ID, "private", {"X-Amzn-Trace-Id": "x\nsecret"}))


@pytest.mark.parametrize(
    "body",
    [
        "not-json",
        json.dumps({"version": 2, "job_id": JOB_ID, "prompt": "x"}),
        json.dumps({"version": 1, "job_id": "not-uuid", "prompt": "x"}),
        json.dumps({"version": 1, "job_id": JOB_ID, "prompt": " "}),
    ],
)
def test_task_deserialization_rejects_malformed_or_unsupported_messages(body):
    with pytest.raises((TypeError, ValueError)):
        deserialize_task(body)


def test_sqs_publish_and_receive_use_safe_bounded_contract():
    response = {
        "Messages": [
            {
                "MessageId": "message-1",
                "ReceiptHandle": "receipt-secret",
                "Body": serialize_task(JobTask(JOB_ID, "private")),
                "Attributes": {"ApproximateReceiveCount": "3"},
            }
        ]
    }
    client = FakeSQS(response)
    queue = SQSJobQueue(client, "https://sqs.example/queue")

    received = queue.receive(20)
    queue.delete(received.receipt_handle)

    assert received.task == JobTask(JOB_ID, "private")
    assert received.receive_count == 3
    receive_call = client.calls[0][1]
    assert receive_call["MaxNumberOfMessages"] == 1
    assert receive_call["WaitTimeSeconds"] == 20
    assert receive_call["AttributeNames"] == ["ApproximateReceiveCount"]
    assert client.calls[1][0] == "delete_message"


def test_sqs_invalid_message_exposes_metadata_but_not_body():
    client = FakeSQS(
        {
            "Messages": [
                {
                    "MessageId": "bad-1",
                    "ReceiptHandle": "receipt",
                    "Body": "private malformed payload",
                    "Attributes": {"ApproximateReceiveCount": "2"},
                }
            ]
        }
    )

    with pytest.raises(InvalidQueueMessageError) as exc:
        SQSJobQueue(client, "queue").receive()

    assert exc.value.message_id == "bad-1"
    assert exc.value.receive_count == 2
    assert "private malformed payload" not in str(exc.value)


def test_sqs_client_failures_are_redacted():
    error = ClientError(
        {"Error": {"Code": "AccessDenied", "Message": "credential=secret"}},
        "SendMessage",
    )
    queue = SQSJobQueue(FakeSQS(error=error), "queue")

    with pytest.raises(DurableJobStoreError) as exc:
        queue.publish(JobTask(JOB_ID, "private"))

    assert "secret" not in str(exc.value)


def test_dynamodb_create_uses_ttl_condition_and_never_persists_prompt():
    client = FakeDynamo()
    repository = DynamoDBJobRepository(client, "jobs", ttl_seconds=3600)

    record = repository.create(JOB_ID)

    call = client.calls[0][1]
    assert record.status is JobStatus.PENDING
    assert call["ConditionExpression"] == "attribute_not_exists(job_id)"
    assert "expires_at" in call["Item"]
    assert "prompt" not in call["Item"]


def test_dynamodb_get_consistent_read_and_numeric_deserialization():
    client = FakeDynamo()
    client.responses["get_item"] = {
        "Item": item(
            "succeeded",
            output={"S": "answer"},
            model_id={"S": "model"},
            input_tokens={"N": "4"},
            output_tokens={"N": "2"},
            estimated_cost={"N": "0.001"},
        )
    }

    record = DynamoDBJobRepository(client, "jobs").get(JOB_ID)

    assert record.output == "answer"
    assert record.input_tokens == 4
    assert record.estimated_cost == 0.001
    assert client.calls[0][1]["ConsistentRead"] is True


def test_dynamodb_running_transition_is_reclaimable_and_success_is_conditional():
    client = FakeDynamo()
    client.responses["update_item"] = {"Attributes": item("running")}
    repository = DynamoDBJobRepository(client, "jobs")

    repository.mark_running(JOB_ID)
    running_call = client.calls[-1][1]
    assert "IN (:pending, :running)" in running_call["ConditionExpression"]

    client.responses["update_item"] = {"Attributes": item("succeeded")}
    repository.mark_succeeded(JOB_ID, JobOutcome("answer", "model", 1, 2, 0.1))
    success_call = client.calls[-1][1]
    assert success_call["ConditionExpression"] == "#status = :running"
    assert success_call["ExpressionAttributeValues"][":estimated_cost"] == {"N": "0.1"}


def test_dynamodb_conditional_failure_maps_to_domain_transition_without_aws_detail():
    client = FakeDynamo()
    client.error = conditional_error()

    with pytest.raises(InvalidJobTransitionError) as exc:
        DynamoDBJobRepository(client, "jobs").mark_running(JOB_ID)

    assert "secret" not in str(exc.value)
