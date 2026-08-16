# Supply-chain verification failure

Use this runbook when development cannot sign or attest an image, Staging
rejects the builder identity or SPDX attestation, or Production rejects the
protected Staging signature. Verification is fail-closed and must complete
before a new ECS task definition is registered.

## Triage

1. Record the workflow run, requested 40-character commit SHA, repository,
   environment, image tag, and resolved digest. Do not retry with a mutable tag.
2. Confirm the workflow checked out the requested SHA and that the successful CI
   and prior-environment gates belong to the same SHA.
3. Compare the ECR source and destination digests. Any mismatch is a security
   incident; stop promotion and preserve both manifests.
4. Run `cosign verify` with the exact expected workflow identity, GitHub issuer,
   and `git_sha` annotation. Do not replace the exact identity with a wildcard.
5. For a development artifact, also run `cosign verify-attestation --type
   spdxjson` and inspect the retained API and Worker SBOM artifacts.

## Failure classes

- **Missing signature or SBOM:** rebuild through the normal development delivery
  workflow. Never create evidence manually under a different identity.
- **Wrong identity or SHA annotation:** freeze all promotions and investigate the
  workflow, repository, branch, and OIDC trust configuration as a potential
  supply-chain compromise.
- **Digest mismatch:** quarantine the destination tag and preserve CloudTrail and
  ECR evidence. Do not overwrite an immutable tag.
- **Fulcio, Rekor, or registry outage:** keep delivery frozen. Existing services
  continue running by digest; retry only after the dependency recovers.
- **Vulnerable image:** remediate and build a new commit. A valid signature does
  not override the ECR CRITICAL/HIGH vulnerability gate.

## Recovery validation

Require a new successful end-to-end run showing the builder signature, SPDX
attestation, unchanged digest, protected Staging signature, protected Production
signature, and digest-pinned ECS task definitions. Retain the failed run URL,
manifest digests, Cosign output, SBOM artifact, CloudTrail evidence, root cause,
and reviewer approval with the incident timeline.
