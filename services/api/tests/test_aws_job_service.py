import pytest
from app.job_service import AwsJobService, get_job_service
from app.main import app
from app.providers.local import LocalProvider

from services.worker.app.aws_jobs import DurableJobStoreError
from services.worker.app.jobs import JobFailure, JobTask


class Repository:
    def __init__(self):
        self.created = None
        self.failed = None
        self.ready = False

    def create(self):
        from services.worker.app.jobs import InMemoryJobRepository

        self.created = InMemoryJobRepository().create()
        return self.created

    def get(self, job_id):
        return self.created

    def mark_failed(self, job_id, failure: JobFailure):
        self.failed = (job_id, failure)

    def check_ready(self):
        self.ready = True


class Queue:
    def __init__(self, error=None):
        self.error = error
        self.published = None
        self.ready = False

    def publish(self, task: JobTask):
        self.published = task
        if self.error:
            raise self.error

    def check_ready(self):
        self.ready = True


def test_aws_service_persists_before_publish_and_readiness_checks_both_dependencies():
    repository, queue = Repository(), Queue()
    service = AwsJobService(repository, queue)

    created = service.submit("private", LocalProvider())
    service.check_ready()

    assert queue.published == JobTask(created.job_id, "private")
    assert repository.ready and queue.ready


def test_publish_failure_marks_orphaned_record_failed_and_remains_redacted():
    repository = Repository()
    service = AwsJobService(
        repository,
        Queue(DurableJobStoreError("safe transport failure")),
    )

    with pytest.raises(DurableJobStoreError):
        service.submit("private", LocalProvider())

    assert repository.failed[0] == repository.created.job_id
    assert repository.failed[1].error_code == "enqueue_failed"


class UnavailableService:
    def submit(self, prompt, provider):
        raise DurableJobStoreError(f"private={prompt}")

    def get(self, job_id):
        raise DurableJobStoreError(f"private={job_id}")

    def check_ready(self):
        raise DurableJobStoreError("credential=secret")

    def shutdown(self, wait=True):
        pass


def test_api_redacts_durable_backend_failure_and_marks_readiness_unavailable(
    client, override_provider
):
    override_provider(LocalProvider())
    app.dependency_overrides[get_job_service] = lambda: UnavailableService()

    submit = client.post("/v1/jobs", json={"prompt": "do-not-expose"})
    ready = client.get("/ready")

    assert submit.status_code == 503
    assert submit.headers["Retry-After"] == "5"
    assert submit.json()["error"]["code"] == "job_service_unavailable"
    assert "do-not-expose" not in submit.text
    assert ready.status_code == 503
    assert "secret" not in ready.text
