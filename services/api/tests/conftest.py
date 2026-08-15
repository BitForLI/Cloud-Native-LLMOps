import pytest
from app.job_service import reset_job_service
from app.main import app
from app.metrics import get_metrics
from app.providers.factory import clear_provider_cache, get_provider
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def reset_application_state():
    reset_job_service()
    app.dependency_overrides.clear()
    get_metrics().reset()
    clear_provider_cache()
    yield
    reset_job_service()
    app.dependency_overrides.clear()
    get_metrics().reset()
    clear_provider_cache()


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def override_provider():
    def apply(provider):
        app.dependency_overrides[get_provider] = lambda: provider

    return apply
