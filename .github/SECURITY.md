# Security Policy

## Project status and supported versions

ZigFS is under active development and is currently described as a release candidate in the
[project README](../README.md). It does not currently document an LTS or security backport policy.
Do not assume that older releases, image tags, or development snapshots receive security fixes.

Include the exact affected version, commit, or image digest in a report. If possible, indicate
whether the issue also occurs on the latest available revision, using an isolated test environment.
A report is still welcome if you cannot verify it against a newer version.

Before upgrading, review the release notes and [backup and recovery guide](../docs/backup-and-recovery.md).
Development versions may change the storage format; do not assume an in-place upgrade is supported.

## Reporting a vulnerability

Please do not publish exploitable vulnerabilities in public issues, pull requests, discussions,
or compatibility reports.

If private vulnerability reporting is enabled for this repository, use GitHub's
[Report a vulnerability](https://github.com/molast/zigfs/security/advisories/new) form, also available
from the repository's **Security** tab. Reports submitted through that form are private.

If that option is unavailable, use a private contact method explicitly published by the
[maintainer](https://github.com/molast). If no private channel is listed, open an issue asking only
for a private security contact. Do not include vulnerability details, affected endpoints, payloads,
or sensitive attachments in that public request.

## What to include

Provide enough information to reproduce the issue safely:

- Affected components, versions or commits, and Docker image tags or digests, if applicable.
- Operating system, architecture, deployment method, and relevant redacted configuration.
- A description of the vulnerability, prerequisites, and required privileges or network access.
- Minimal reproduction steps or a proof of concept using synthetic data and test credentials.
- Expected and actual behavior, relevant request IDs, and redacted logs or response excerpts.
- The potential impact, such as unauthorized access, privilege escalation, data exposure,
  corruption, or denial of service.
- Any known mitigation or proposed fix, and whether the report is already disclosed elsewhere.

Never include production credentials, access keys, session tokens, cookies, SSE-C keys, master keys,
or live presigned URLs. Memory dumps and data directories may contain secrets and object contents;
do not attach them without reviewing their contents and agreeing on a private sharing method.

## Scope

Security reports may concern any maintained component in this repository, including:

- S3 request signing, authentication, IAM policies, and authorization boundaries.
- Management API authentication, sessions, and administrative permissions.
- Admin BFF and Web security, including browser and upstream request handling.
- Object storage, metadata, path handling, recovery, and resource exhaustion.
- CLI credential handling, release artifacts, dependencies, and deployment configuration.

Use the [issue templates](https://github.com/molast/zigfs/issues/new/choose) for ordinary bugs,
feature requests, and performance or compatibility issues that do not expose a vulnerability.
If the security impact is unclear, start with a private report.

## Review and disclosure

Private reports allow maintainers and reporters to clarify impact, reproduce the issue, and
coordinate a fix and disclosure. Keep technical details private until a disclosure plan has been
agreed upon. Any advisory should describe affected versions, available fixes, and mitigations.

This policy does not promise a response deadline, a fix date, a CVE assignment, or a bounty.
Reporters may state their preferred attribution or request to remain anonymous.

## Deployment guidance

Replace default credentials before exposing an instance, restrict administrative access, and keep
credentials and local data out of Git. Admin must communicate with ZigFS through its APIs and must
not directly access the data directory.

See the [configuration reference](../docs/configuration.md),
[network deployment guide](../docs/deployment/network.md), and
[operations guide](../docs/operations.md) for deployment details.
