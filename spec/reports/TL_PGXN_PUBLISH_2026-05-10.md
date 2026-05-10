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

### BLOCKER-1 (P1): `extension/Makefile` missing `pgmnemo--0.2.1.sql` from DATA list

**File:** `extension/Makefile:1-2`

The `DATA` variable in `extension/Makefile` lists all SQL files explicitly but stops at `pgmnemo--0.2.0.1--0.2.1.sql`. It does **not** include `pgmnemo--0.2.1.sql` (the fresh-install script).

**Impact:** `pgxn install pgmnemo` installs via `make install` which invokes PGXS using `extension/Makefile`. Since `pgmnemo--0.2.1.sql` is absent from DATA, it will **not** be copied to `$(sharedir)/extension/`. A user running:
```sql
CREATE EXTENSION pgmnemo VERSION '0.2.1';
```
on a fresh PG instance will get `ERROR: could not open file "pgmnemo--0.2.1.sql"`.

**Fix required:**
```makefile
# extension/Makefile line ~2 — append pgmnemo--0.2.1.sql
DATA = pgmnemo--0.0.1.sql \
       ... \
       pgmnemo--0.2.0.1--0.2.1.sql \
       pgmnemo--0.2.1.sql          # ← ADD THIS
```

### BLOCKER-2 (P2): No `pgxn upload` CLI — web upload required

pgxnclient 1.3.2 exposes: `check, download, help, info, install, load, mirror, search, uninstall, unload`. There is **no `upload` command**. Upload was removed from the client; it must be performed via the PGXN Manager web UI at `manager.pgxn.org`.

**Requires:**
1. Maintainer account on manager.pgxn.org (or `https://pgxn.org/account`)
2. A zip file: `pgmnemo-0.2.1.zip` structured as `pgmnemo-0.2.1/<all bundle files>`
3. Upload via web form

### ISSUE-3 (cosmetic): `Makefile:2` has `EXTVERSION = 0.0.1`

Top-level `Makefile:2` defines `EXTVERSION = 0.0.1`. This variable is never used in any rule (DATA uses `$(wildcard extension/*--*.sql)`), but it is misleading to contributors and auditors. Should be `0.2.1`.

---

## 4. Pre-Upload Checklist

- [x] META.json validates against PGXN spec 1.0.0
- [x] `extension/pgmnemo.control` has `default_version = '0.2.1'`
- [x] `extension/pgmnemo--0.2.1.sql` (fresh install) exists
- [x] `extension/pgmnemo--0.2.0.1--0.2.1.sql` (upgrade) exists
- [x] README.md, CHANGELOG.md, LICENSE present
- [x] Git tag `v0.2.1` exists
- [ ] **`extension/Makefile` DATA list includes `pgmnemo--0.2.1.sql`** ← BLOCKER
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
| Blockers to pgxn install working | 1 (extension/Makefile DATA list) |
| pgxnclient upload command available | NO — web UI required |
| Git tag v0.2.1 | exists locally |
| Est. fix time before upload-ready | ~15 min (2 Makefile fixes + zip creation) |

---

## 7. Self-Evaluation

**What worked:** META.json is genuinely clean and PGXN-spec-compliant. The SQL artifact set (fresh-install + upgrade script) is complete. All required docs are present. Bundle would be ~81 KB, well-structured.

**What to improve:** The `extension/Makefile` DATA list is a maintenance trap — it's a static enumeration that requires manual updates every release. A `$(wildcard extension/*--*.sql)` pattern (as used in the top-level Makefile) would be safer and self-maintaining.

**Risk note:** PGXN upload cannot be automated from this environment — it requires maintainer credentials on manager.pgxn.org. The evidence threshold ("pgxn install pgmnemo works on a clean machine") cannot be confirmed until the upload is done and the listing appears.
