# Security Policy

## Supported Versions

| Version | Supported | PG range | pgvector |
|---|---|---|---|
| 0.4.x | ✅ Yes (current) | 14 – 17 | ≥ 0.7.0 |
| 0.3.x | ✅ Yes (security only) | 14 – 17 | ≥ 0.7.0 |
| 0.2.x | ⚠️ Critical fixes only (until 2026-09-01) | 14 – 17 | ≥ 0.7.0 |
| ≤ 0.1.x | ❌ Not supported | — | — |

Policy: the two most recent minor versions receive routine security updates.
Older versions receive critical-severity fixes for 90 days after the next
minor release, then go end-of-life. See `README.md` § Compatibility matrix.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please use **[GitHub Security Advisories](https://github.com/pgmnemo/pgmnemo/security/advisories/new)** to report vulnerabilities privately. This ensures the report is visible only to repository maintainers and not publicly disclosed prematurely.

**Do not open a public GitHub issue for security vulnerabilities.**

Include in your report:
- A description of the vulnerability and its potential impact
- Steps to reproduce or a minimal proof-of-concept
- PostgreSQL version, pgmnemo version, and pgvector version
- Any relevant log output (redact sensitive data before sending)

**Response time commitment:**
- Initial acknowledgment within 7 days
- Assessment and severity rating within 10 business days
- A fix or mitigation plan communicated before public disclosure
- Credit in the CHANGELOG and release notes (unless you prefer to remain anonymous)

We follow a **coordinated disclosure** model. Please allow reasonable time (typically 90 days) for a fix to be prepared and released before publishing details publicly.

## Scope

This policy covers the pgmnemo PostgreSQL extension code in this repository. It does not cover:
- Third-party dependencies (pgvector, PostgreSQL core) — report those to their respective projects
- Infrastructure or hosting environments operated by users
