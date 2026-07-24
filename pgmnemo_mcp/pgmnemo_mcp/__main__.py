"""python -m pgmnemo_mcp — CLI entry point with --smoke flag and subcommands.

Subcommands
-----------
init    Configure pgmnemo MCP server for your AI CLI (Claude Code, Codex, Gemini).
export  Export pgmnemo corpus to human-readable markdown.

Flags (legacy, apply when no subcommand is given)
--------------------------------------------------
--smoke  Run a connectivity smoke test.
"""

import argparse
import sys


def main() -> None:
    # Route 'init' subcommand to init_cmd before the main parser sees it, so
    # that 'pgmnemo init --help' works cleanly without argparse confusion.
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        from .init_cmd import main as _init_main
        _init_main()
        return

    parser = argparse.ArgumentParser(prog="pgmnemo")
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run a connectivity smoke test: connect to DB and call recall_lessons().",
    )
    subparsers = parser.add_subparsers(dest="command")
    # Register the `export` subcommand (args parsed inside main_export)
    subparsers.add_parser(
        "export",
        help="Export pgmnemo corpus to human-readable markdown.",
        add_help=False,
    )
    args, remaining = parser.parse_known_args()

    if args.smoke:
        _run_smoke()
    elif args.command == "export":
        from .export import main_export
        main_export(remaining)
    else:
        from .server import run
        run()


def _run_smoke() -> None:
    from .config import DATABASE_URL, get_pool

    print(f"pgmnemo-mcp smoke: connecting to {_redact(DATABASE_URL)} …")
    try:
        pool = get_pool()
        conn = pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT count(*) FROM pgmnemo.recall_lessons("
                    "NULL::vector(1024), 5, NULL, NULL, 'test')"
                )
                row = cur.fetchone()
            pool.putconn(conn)
        except Exception:
            pool.putconn(conn)
            raise
    except Exception as exc:
        print(f"pgmnemo-mcp smoke: FAIL — {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"pgmnemo-mcp smoke: OK (recall_lessons returned {row[0]} rows)")
    sys.exit(0)


def _redact(url: str) -> str:
    """Hide password in DATABASE_URL for safe printing."""
    import re
    return re.sub(r"://([^:@]+):([^@]+)@", r"://\1:***@", url)


if __name__ == "__main__":
    main()
