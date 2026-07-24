"""pgmnemo_mcp.hooks — CLI-agnostic session lifecycle hook scripts.

Three shared scripts work across Claude Code / Codex / Gemini via per-CLI
event-mapping configs in integrations/{claude,codex,gemini}/.

Scripts are invoked as ``python -m pgmnemo_mcp.hooks.<name>``:
- session_recall   : SessionStart / BeforeAgent  → recall top-K lessons
- session_capture  : Stop / SessionEnd           → ingest session outcome
- session_backup   : PreCompact / PreCompress    → backup session transcript

CLI-agnostic project-dir resolution (in priority order):
    CLAUDE_PROJECT_DIR → CODEX_PROJECT_DIR → GEMINI_PROJECT_DIR → "."
"""

HOOK_SCRIPTS = ("session_recall", "session_capture", "session_backup")
