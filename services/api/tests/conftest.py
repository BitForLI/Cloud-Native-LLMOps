import pytest
from app.main import app
from app.metrics import get_metrics
from app.providers.factory import clear_provider_cache


@pytest.fixture(autouse=True)
def reset_application_state():
    app.dependency_overrides.clear()
    get_metrics().reset()
    clear_provider_cache()
    yield
    app.dependency_overrides.clear()
    get_metrics().reset()
    clear_provider_cache()

