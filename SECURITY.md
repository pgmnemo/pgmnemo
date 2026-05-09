# Security Policy

## Supported Versions

`pgmnemo` is still in beta.

We provide best-effort security support for:

| Version | Supported |
|---|---|
| latest published release | yes |
| previous patch release in the same minor line | best effort |
| older releases | no |
| unreleased `main` snapshots | no security support contract |

## Reporting a Vulnerability

Please do **not** open a public GitHub issue for suspected security vulnerabilities.

Instead:

1. Email the maintainer address listed on the project profile or release notes.
2. Include:
   - affected `pgmnemo` version
   - PostgreSQL version
   - `pgvector` version
   - reproduction steps or proof of concept
   - expected impact

Target response times:

- acknowledgement: within 72 hours
- initial triage: within 7 days
- public disclosure coordination: after a fix or mitigation exists

## Scope

Security issues include:
- privilege escalation
- RLS / tenant-isolation bypass
- data leakage across role / project boundaries
- unsafe extension install / upgrade behavior
- malformed input leading to privilege abuse

Non-security bugs should go to GitHub Issues.
