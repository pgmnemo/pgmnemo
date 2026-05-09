#!/usr/bin/env python3
"""
Zep adapter for pgmnemo benchmark harness.

Install (cloud/managed):
    pip install zep-cloud>=2.5.0
    Set ZEP_API_KEY env var (https://www.getzep.com)

Install (self-hosted):
    docker run -d --name zep -p 8000:8000 ghcr.io/getzep/zep:latest
    pip install zep-python>=2.0.0
    Set ZEP_BASE_URL=http://localhost:8000

Hypothesis:     Zep temporal knowledge-graph retrieval vs. pgmnemo cosine recall.
IV:             memory backend (Zep vs. pgmnemo)
DV:             recall@K on LoCoMo / LongMemEval toy fixture
Control:        identical queries, identical episode text, K=5
Treatment:      zep.memory.search_sessions() or client.memory.search()
Power:          N>=50 episodes per fixture sufficient for d>=0.5 at alpha=0.05, power=0.80
Confounds:      Zep entity extraction alters stored content; graph edges not present in
                pgmnemo baseline; embedding model may differ.
"""
from __future__ import annotations

import os
import time
import uuid
from typing import Any


# ---------------------------------------------------------------------------
# Toy stub
# ---------------------------------------------------------------------------

class _MockZep:
    def __init__(self) -> None:
        self._sessions: dict[str, list[dict]] = {}

    def add_session(self, session_id: str, **_: Any) -> None:
        self._sessions.setdefault(session_id, [])

    def add_memory(self, session_id: str, messages: list[dict], **_: Any) -> None:
        self._sessions.setdefault(session_id, [])
        for m in messages:
            self._sessions[session_id].append(m)

    def search(self, session_id: str, query: str, limit: int = 5, **_: Any) -> list[dict]:
        msgs = self._sessions.get(session_id, [])
        hits = [m for m in msgs if any(w in m.get("content", "").lower() for w in query.lower().split())]
        return (hits or msgs)[:limit]

    def search_all(self, query: str, limit: int = 5) -> list[dict]:
        all_msgs = [m for msgs in self._sessions.values() for m in msgs]
        hits = [m for m in all_msgs if any(w in m.get("content", "").lower() for w in query.lower().split())]
        return (hits or all_msgs)[:limit]


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------

class ZepAdapter:
    """
    Exposes write_episode / recall_topk over Zep memory.

    Args:
        session_id:  Zep session identifier (per-conversation namespace)
        use_mock:    bypass real Zep (set True or env MOCK_ADAPTERS=1)
        base_url:    Zep self-hosted URL (default env ZEP_BASE_URL or cloud)
        api_key:     Zep API key (default env ZEP_API_KEY)
    """

    def __init__(
        self,
        session_id: str | None = None,
        use_mock: bool = False,
        base_url: str | None = None,
        api_key: str | None = None,
    ) -> None:
        self.session_id = session_id or f"bench_{uuid.uuid4().hex[:8]}"
        self._mock = use_mock or os.getenv("MOCK_ADAPTERS", "0") == "1"

        if self._mock:
            self._client = _MockZep()
            self._client.add_session(self.session_id)
            return

        _api_key = api_key or os.getenv("ZEP_API_KEY", "")
        _base_url = base_url or os.getenv("ZEP_BASE_URL", "")

        if _base_url:
            # Self-hosted: zep-python
            try:
                from zep_python import ZepClient  # type: ignore[import]
            except ImportError as exc:
                raise ImportError("pip install zep-python>=2.0.0") from exc
            self._client = ZepClient(base_url=_base_url, api_key=_api_key or None)
            self._mode = "self_hosted"
        else:
            # Cloud: zep-cloud
            try:
                from zep_cloud.client import Zep  # type: ignore[import]
            except ImportError as exc:
                raise ImportError("pip install zep-cloud>=2.5.0") from exc
            self._client = Zep(api_key=_api_key)
            self._mode = "cloud"

        self._ensure_session()

    # ------------------------------------------------------------------

    def _ensure_session(self) -> None:
        try:
            from zep_cloud.types import Session  # type: ignore[import]
            self._client.memory.add_session(Session(session_id=self.session_id))
        except Exception:
            pass  # session may already exist

    def write_episode(self, episode: dict) -> None:
        """
        Ingest one episode into Zep.

        episode schema:
          session_id: str  (overrides adapter default if provided)
          messages:   list[{role: str, content: str}]
          metadata:   dict (optional)
        """
        sid = episode.get("session_id", self.session_id)
        messages = episode.get("messages", [])

        if self._mock:
            self._client.add_memory(sid, messages)
            return

        try:
            from zep_cloud.types import Message  # type: ignore[import]
            zep_msgs = [
                Message(role_type=m["role"], content=m["content"])
                for m in messages
            ]
            self._client.memory.add(sid, messages=zep_msgs)
        except Exception:
            # fallback for zep-python self-hosted
            from zep_python.memory.models import Message as ZMessage  # type: ignore[import]
            from zep_python.memory.models import Memory as ZMemory  # type: ignore[import]
            zmem = ZMemory(messages=[ZMessage(role=m["role"], content=m["content"]) for m in messages])
            self._client.memory.add_memory(sid, zmem)

    def recall_topk(self, query: str, k: int = 5) -> list[str]:
        """Return up to k memory strings most relevant to query."""
        if self._mock:
            hits = self._client.search_all(query, limit=k)
            return [h.get("content", str(h)) for h in hits]

        try:
            # zep-cloud
            results = self._client.memory.search_sessions(
                text=query, limit=k, search_scope="facts"
            )
            items = getattr(results, "results", []) or []
            return [getattr(r, "fact", str(r)) for r in items]
        except Exception:
            try:
                # zep-python self-hosted
                results = self._client.memory.search_memory(
                    self.session_id, query, limit=k
                )
                return [r.message.content for r in results if r.message]
            except Exception:
                return []

    def reset(self) -> None:
        if self._mock:
            self._client._sessions.pop(self.session_id, None)
            return
        try:
            self._client.memory.delete(self.session_id)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CLI smoke-test entry-point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse, json, sys
    from pathlib import Path

    ap = argparse.ArgumentParser(description="Zep adapter smoke-test")
    ap.add_argument("--mock", action="store_true", default=True)
    ap.add_argument("--fixture", default=None)
    args = ap.parse_args()

    adapter = ZepAdapter(use_mock=args.mock)

    fixture = [
        {
            "session_id": adapter.session_id,
            "messages": [
                {"role": "user", "content": "Alice's birthday is on March 14."},
                {"role": "assistant", "content": "Got it."},
            ],
        },
        {
            "session_id": adapter.session_id,
            "messages": [
                {"role": "user", "content": "Bob likes hiking in the mountains."},
                {"role": "assistant", "content": "Noted."},
            ],
        },
    ]
    if args.fixture:
        fixture = json.loads(Path(args.fixture).read_text())

    for ep in fixture:
        adapter.write_episode(ep)

    results = adapter.recall_topk("When is Alice's birthday?", k=3)
    print(json.dumps({"adapter": "zep", "query": "When is Alice's birthday?", "results": results}))

    if not results:
        print("FAIL: empty results", file=sys.stderr)
        sys.exit(1)
    print("PASS", file=sys.stderr)
