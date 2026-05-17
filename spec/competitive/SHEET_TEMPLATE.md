# SHEET_TEMPLATE — EA-FETCH FAILURE

**Task**: PGMNEMO-WG-VC-260517 — EA-FETCH: pull startup template from Google Sheets  
**Date**: 2026-05-17  
**Assignee**: EA (agent_id=4)

---

## FAILURE: Could not fetch Google Sheet

**Source**: `https://docs.google.com/spreadsheets/d/1SKNHJwcytVMJmgXKD-LCdruKZTnHTXR4/edit?gid=2108518644`  
**Spreadsheet ID**: `1SKNHJwcytVMJmgXKD-LCdruKZTnHTXR4`  
**Sheet GID**: `2108518644`

### Tools attempted (in order)

| Step | Tool / Path | Result |
|------|-------------|--------|
| 1 | Google Workspace MCP (`mcp__google_workspace__*`) | Not available in this agent session |
| 2 | `POST /api/connections/accounts/12/refresh-token` (app API) | `{"status":"error","message":"Token refresh failed: 400"}` |
| 3 | Fernet-decrypt `credential_records` id=33 → `oauth2.googleapis.com/token` refresh | `HTTP 400: invalid_grant — Token has been expired or revoked` |

### Root cause

The Google OAuth2 refresh token for external account `id=12` (`asistentgaidaburas@gmail.com`) has been **expired or revoked** by Google. The credential was last health-checked on 2026-05-03; the token may have been revoked since then (Google revokes tokens after 6 months of inactivity or if the OAuth app is flagged).

The stored scope **includes** `https://www.googleapis.com/auth/spreadsheets`, so re-authorization would grant Sheets access immediately.

### Recommendation for founder

**Option A (fastest)**: Re-authorize the Google Workspace connection:
1. Go to Agency admin → Connections → Google Workspace (`asistentgaidaburas@gmail.com`) → Reconnect
2. Complete the OAuth flow — this will issue a new refresh token
3. Re-run this task; EA will fetch and convert the sheet automatically

**Option B (manual, no re-auth needed)**:
1. Open the spreadsheet and go to the tab with GID `2108518644`
2. File → Download → CSV
3. Place the CSV at `spec/competitive/startup_template.csv`
4. The RATIFY task will work from the CSV directly

### Note for RATIFY task

`SHEET_TEMPLATE.md` is unavailable. Per task spec, RATIFY should fall back to generic template. If the founder exports a CSV manually, it can be converted to markdown with:

```bash
python3 -c "
import csv, sys
rows = list(csv.reader(open('spec/competitive/startup_template.csv')))
if not rows: exit()
print('| ' + ' | '.join(rows[0]) + ' |')
print('|' + '---|' * len(rows[0]))
for r in rows[1:]: print('| ' + ' | '.join(r) + ' |')
"
```
