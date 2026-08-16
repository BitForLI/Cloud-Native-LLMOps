import re
from pathlib import Path

import yaml

GITHUB_DIR = Path(__file__).parents[1]
WORKFLOWS = {
    name: GITHUB_DIR / "workflows" / filename
    for name, filename in {
        "development": "deploy-dev.yml",
        "staging": "promote-staging.yml",
        "production": "release-production.yml",
    }.items()
}


def load(path):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_all_delivery_stages_install_one_pinned_cosign_version():
    for path in WORKFLOWS.values():
        job = next(iter(load(path)["jobs"].values()))
        installer = next(
            step for step in job["steps"] if step["name"] == "Install pinned Cosign"
        )

        assert installer["uses"] == (
            "sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6"
        )
        assert installer["with"]["cosign-release"] == "v3.0.6"
        assert job["permissions"]["id-token"] == "write"


def test_development_generates_retains_and_attests_both_spdx_sboms():
    job = load(WORKFLOWS["development"])["jobs"]["deploy"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    sbom_installer = next(
        step for step in job["steps"] if step["name"] == "Install pinned Syft"
    )
    evidence = next(
        step for step in job["steps"] if step["name"] == "Retain immutable build SBOMs"
    )

    assert sbom_installer["uses"] == (
        "anchore/sbom-action/download-syft@e22c389904149dbc22b58101806040fa8d37a610"
    )
    assert sbom_installer["with"]["syft-version"] == "v1.50.0"
    assert "api.spdx.json" in scripts and "worker.spdx.json" in scripts
    assert "cosign attest --yes --type spdxjson" in scripts
    assert "cosign verify-attestation" in scripts
    assert evidence["if"] == "always()"
    assert evidence["with"]["retention-days"] == "90"
    assert evidence["with"]["if-no-files-found"] == "error"


def test_promotion_chain_uses_exact_workflow_identities_and_commit_annotation():
    staging_script = (GITHUB_DIR / "scripts" / "promote-staging.sh").read_text(
        encoding="utf-8"
    )
    production_script = (GITHUB_DIR / "scripts" / "promote-production.sh").read_text(
        encoding="utf-8"
    )

    assert "deploy-dev.yml@refs/heads/master" in staging_script
    assert "promote-staging.yml@refs/heads/master" in staging_script
    assert "promote-staging.yml@refs/heads/master" in production_script
    assert "release-production.yml@refs/heads/master" in production_script
    for script in (staging_script, production_script):
        assert "--certificate-identity" in script
        assert 'oidc_issuer="https://token.actions.githubusercontent.com"' in script
        assert '--annotations "git_sha=${IMAGE_TAG}"' in script
        assert "certificate-identity-regexp" not in script


def test_every_environment_deploys_verified_digest_not_mutable_tag():
    dev = WORKFLOWS["development"].read_text(encoding="utf-8")
    staging = (GITHUB_DIR / "scripts" / "promote-staging.sh").read_text(
        encoding="utf-8"
    )
    production = (GITHUB_DIR / "scripts" / "promote-production.sh").read_text(
        encoding="utf-8"
    )

    for delivery in (dev, staging, production):
        assert re.search(r'api_image=.*@\$\{api_digest\}', delivery)
        assert re.search(r'worker_image=.*@\$\{worker_digest\}', delivery)
        task_registration = delivery.index("register-task-definition")
        assert delivery.index("cosign verify") < task_registration
