"""python -m pgmnemo_mcp — CLI entry point with --smoke flag."""

import argparse
import sys


def main() -> None:
    parser = argparse.ArgumentParser(prog="pgmnemo-mcp")
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run a connectivity smoke test: connect to DB and call recall_lessons().",
    )
    args = parser.parse_args()

    if args.smoke:
        _run_smoke()
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
