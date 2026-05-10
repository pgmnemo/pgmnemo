# TL Report: P1.1-PGXN-PUBLISH — Submit pgmnemo v0.2.1 to PGXN

**Date:** 2026-05-10
**Task:** P1.1-PGXN-PUBLISH
**Priority:** P3
**Deadline:** 2026-05-23

---

## 1. META.json Validation

**Result: PASS**

Manual validation against PGXN Meta Spec 1.0.0 (pgxnclient 1.3.2 does not expose a `validate-meta` command):

| Field | Value | Status |
|-------|-------|--------|
| `name` | pgmnemo | ✓ |
| `abstract` | present, ≤255 chars | ✓ |
| `version` | 0.2.1 | ✓ |
| `maintainer` | Alex Gaydabura <asistentgaidaburas@gmail.com> | ✓ |
| `license` | apache_2_0 | ✓ valid PGXN enum |
| `provides.pgmnemo.version` | 0.2.1 | ✓ matches top-level |
| `meta-spec.version` | 1.0.0 | ✓ |
| `release_status` | stable | ✓ |
| `resources` | homepage, bugtracker, repository | ✓ |

META.json is PGXN-ready as stated in the audit.

---

## 2. Bundle Readiness Assessment

### Files present (bundle root)

| File | Size | Status |
|------|------|--------|
| META.json | 1,850 B | ✓ |
| README.md | 5,146 B | ✓ |
| CHANGELOG.md | 10,007 B | ✓ |
| LICENSE | 11,337 B (Apache 2.0) | ✓ |
| Makefile | 744 B | ✓ (see issue #1) |
| extension/pgmnemo.control | 288 B | ✓ `default_version = '0.2.1'` |
| extension/pgmnemo--0.2.1.sql | 33,445 B | ✓ fresh-install script |
| extension/pgmnemo--0.2.0.1--0.2.1.sql | 20,514 B | ✓ upgrade script |

**Projected bundle size:** ~81 KB (well within PGXN limit)

**Git tag:** `v0.2.1` exists locally ✓

---

## 3. Blockers Found

### BLOCKER-1 (P1): `extension/Makefile` missing `pgmnemo--0.2.1.sql` from DATA list — **FIXED**

**File:** `extension/Makefile:19`

`pgmnemo--0.2.1.sql` (fresh-install script) was absent from the `DATA` variable. Without it, `make install` would not copy the file to `$(sharedir)/extension/` and `CREATE EXTENSION pgmnemo VERSION '0.2.1'` would fail on a clean machine.

**Fix applied:** Appended `pgmnemo--0.2.1.sql` to the DATA list in `extension/Makefile` (line 20). Verified via direct edit.

### BLOCKER-2 (P2): No `pgxn upload` CLI — web upload required

pgxnclient 1.3.2 exposes: `check, download, help, info, install, load, mirror, search, uninstall, unload`. There is **no `upload` command**. Upload was removed from the client; it must be performed via the PGXN Manager web UI at `manager.pgxn.org`.

**Requires:**
1. Maintainer account on manager.pgxn.org (or `https://pgxn.org/account`)
2. A zip file: `pgmnemo-0.2.1.zip` structured as `pgmnemo-0.2.1/<all bundle files>`
3. Upload via web form

### ISSUE-3 (cosmetic): `Makefile:2` had `EXTVERSION = 0.0.1` — **FIXED**

Top-level `Makefile:2` defined `EXTVERSION = 0.0.1`. Updated to `0.2.1` to match the actual release version. (Variable is not used in rules, but misleading to contributors and auditors.)

---

## 4. Pre-Upload Checklist

- [x] META.json validates against PGXN spec 1.0.0
- [x] `extension/pgmnemo.control` has `default_version = '0.2.1'`
- [x] `extension/pgmnemo--0.2.1.sql` (fresh install) exists
- [x] `extension/pgmnemo--0.2.0.1--0.2.1.sql` (upgrade) exists
- [x] README.md, CHANGELOG.md, LICENSE present
- [x] Git tag `v0.2.1` exists
- [x] **`extension/Makefile` DATA list includes `pgmnemo--0.2.1.sql`** ← FIXED
- [ ] Maintainer has manager.pgxn.org account
- [ ] Bundle zip created: `pgmnemo-0.2.1.zip`
- [ ] Bundle uploaded via manager.pgxn.org web UI
- [ ] Verify `pgxn info pgmnemo` returns v0.2.1

---

## 5. Remediation Tasks

### task_draft: FIX-PGXN-MAKEFILE-DATA

```
Title: Add pgmnemo--0.2.1.sql to extension/Makefile DATA list
File: extension/Makefile
Change: Append `pgmnemo--0.2.1.sql \` to DATA variable
Priority: P1 (blocks pgxn install pgmnemo)
Effort: 1 line change, 5 minutes
```

### task_draft: FIX-MAKEFILE-EXTVERSION

```
Title: Update top-level Makefile EXTVERSION from 0.0.1 to 0.2.1
File: Makefile:2
Change: EXTVERSION = 0.0.1 → EXTVERSION = 0.2.1
Priority: P3 (cosmetic)
Effort: 1 line change, 5 minutes
```

### task_draft: PGXN-UPLOAD-MANUAL

```
Title: Maintainer uploads pgmnemo-0.2.1.zip to manager.pgxn.org
Steps:
  1. pip install pgxnclient (for local validate/test only)
  2. From repo root: zip -r pgmnemo-0.2.1.zip META.json README.md CHANGELOG.md LICENSE Makefile extension/pgmnemo.control extension/pgmnemo--0.2.1.sql extension/pgmnemo--0.2.0.1--0.2.1.sql
  3. Upload at manager.pgxn.org with pgmnemo-0.2.1.zip
  4. Verify: pgxn info pgmnemo (CLI) or https://pgxn.org/dist/pgmnemo/
Owner: Alex Gaydabura (requires maintainer credentials)
Blocker: FIX-PGXN-MAKEFILE-DATA must be done first
```

---

## 6. Metrics

| Metric | Value |
|--------|-------|
| META.json spec compliance | 100% (8/8 required fields valid) |
| Bundle files present | 8/8 ✓ |
| Blockers to pgxn install working | 0 (Makefile DATA fix applied) |
| pgxnclient upload command available | NO — web UI required |
| Git tag v0.2.1 | exists locally |
| extension/Makefile DATA includes pgmnemo--0.2.1.sql | ✓ FIXED |
| Makefile EXTVERSION | 0.2.1 ✓ FIXED |
| Agent runs (7d): total/completed/failed/escalated | 2337 / 981 (42%) / 718 (31%) / 75 (3.2%) |
| Currently RUNNING / total ESCALATED (all-time) | 2 / 174 |
| Remaining manual step | maintainer zip + upload to manager.pgxn.org |

---

## 7. Self-Evaluation

**What worked:** META.json is genuinely clean and PGXN-spec-compliant. The SQL artifact set (fresh-install + upgrade script) is complete. All required docs are present. Bundle would be ~81 KB, well-structured.

**What to improve:** The `extension/Makefile` DATA list is a maintenance trap — it's a static enumeration that requires manual updates every release. A `$(wildcard extension/*--*.sql)` pattern (as used in the top-level Makefile) would be safer and self-maintaining.

**Risk note:** PGXN upload cannot be automated from this environment — it requires maintainer credentials on manager.pgxn.org. The evidence threshold ("pgxn install pgmnemo works on a clean machine") cannot be confirmed until the upload is done and the listing appears.
