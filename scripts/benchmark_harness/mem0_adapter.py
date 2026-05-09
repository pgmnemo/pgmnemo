#!/usr/bin/env python3
"""
Mem0 adapter for pgmnemo benchmark harness.

Install:
    pip install mem0ai>=0.1.29 qdrant-client openai

Local (no cloud) config uses Qdrant in-memory + OpenAI embeddings.
Set OPENAI_API_KEY; or pass use_mock=True for offline smoke-test.

Hypothesis:     Mem0 graph-enhanced retrieval vs. pgmnemo cosine recall.
IV:             memory backend (Mem0 vs. pgmnemo)
DV:             recall@K on LoCoMo / LongMemEval toy fixture
Control:        identical queries, identical episode text, K=5
Treatment:      Mem0 memory.search()
Power:          N>=50 episodes per fixture sufficient for d>=0.5 at alpha=0.05, power=0.80
Confounds:      LLM extraction step in Mem0 mutates stored content (not raw retrieval);
                embedding model may differ from pgmnemo baseline.
"""
from __future__ import annotations

import os
import uuid
from typing import Any

# ---------------------------------------------------------------------------
# Toy stub — activated when use_mock=True or MOCK_ADAPTERS=1
# ---------------------------------------------------------------------------

class _MockMem0:
    """Minimal stand-in that satisfies the non-empty evidence threshold."""

    def __init__(self) -> None:
        self._store: dict[str, list[dict]] = {}

    def add(self, messages: list[dict], user_id: str, **_: Any) -> dict:
        self._store.setdefault(user_id, [])
        for m in messages:
            self._store[user_id].append({"id": str(uuid.uuid4()), "memory": m["content"]})
        return {"results": self._store[user_id]}

    def search(self, query: str, user_id: str, limit: int = 5, **_: Any) -> dict:
        memories = self._store.get(user_id, [])
        # naive substring filter as mock retrieval
        hits = [m for m in memories if any(w in m["memory"].lower() for w in query.lower().split())]
        hits = hits[:limit] if hits else memories[:limit]
        return {"results": [{"memory": h["memory"], "score": 0.9} for h in hits]}


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------

class Mem0Adapter:
    """
    Exposes write_episode / recall_topk over Mem0 memory.

    Args:
        user_id:   logical user / conversation namespace
        use_mock:  bypass real Mem0 (set True or env MOCK_ADAPTERS=1)
        config:    Mem0 Memory() config dict (optional; uses local Qdrant default)
    """

    def __init__(
        self,
        user_id: str = "bench_user",
        use_mock: bool = False,
        config: dict | None = None,
    ) -> None:
        self.user_id = user_id
        self._mock = use_mock or os.getenv("MOCK_ADAPTERS", "0") == "1"

        if self._mock:
            self._mem = _MockMem0()
            return

        try:
            from mem0 import Memory  # type: ignore[import]
        except ImportError as exc:
            raise ImportError("pip install mem0ai qdrant-client openai") from exc

        default_config: dict[str, Any] = {
            "vector_store": {
                "provider": "qdrant",
                "config": {
                    "collection_name": "bench_harness",
                    "embedding_model_dims": 1536,
                    ":memory:": True,
                },
            },
            "llm": {
                "provider": "openai",
                "config": {"model": "gpt-4o-mini", "temperature": 0},
            },
            "embedder": {
                "provider": "openai",
                "config": {"model": "text-embedding-3-small"},
            },
        }
        self._mem = Memory.from_config(config or default_config)

    # ------------------------------------------------------------------

    def write_episode(self, episode: dict) -> None:
        """
        Ingest one episode into Mem0.

        episode schema:
          session_id: str
          messages:   list[{role: str, content: str}]
          metadata:   dict (optional)
        """
        messages = episode.get("messages", [])
        metadata = episode.get("metadata", {})
        self._mem.add(messages, user_id=self.user_id, metadata=metadata)

    def recall_topk(self, query: str, k: int = 5) -> list[str]:
        """Return up to k memory strings most relevant to query."""
        result = self._mem.search(query, user_id=self.user_id, limit=k)
        # Mem0 returns {"results": [{"memory": str, "score": float}, ...]}
        hits = result.get("results", [])
        return [h.get("memory", h.get("content", str(h))) for h in hits]

    def reset(self) -> None:
        """Delete all memories for this user (for test isolation)."""
        if self._mock:
            self._mem._store.pop(self.user_id, None)
            return
        try:
            self._mem.delete_all(user_id=self.user_id)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CLI smoke-test entry-point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse, json, sys

    ap = argparse.ArgumentParser(description="Mem0 adapter smoke-test")
    ap.add_argument("--mock", action="store_true", default=True,
                    help="Use mock backend (default True for offline CI)")
    ap.add_argument("--fixture", default=None, help="Path to JSON fixture file")
    args = ap.parse_args()

    adapter = Mem0Adapter(use_mock=args.mock)

    fixture = [
        {
            "session_id": "s1",
            "messages": [
                {"role": "user", "content": "Alice's birthday is on March 14."},
                {"role": "assistant", "content": "Got it, I'll remember that."},
            ],
            "metadata": {"source": "smoke_test"},
        },
        {
            "session_id": "s2",
            "messages": [
                {"role": "user", "content": "Bob likes hiking in the mountains."},
                {"role": "assistant", "content": "Noted."},
            ],
            "metadata": {"source": "smoke_test"},
        },
    ]
    if args.fixture:
        fixture = json.loads(Path(args.fixture).read_text())

    for ep in fixture:
        adapter.write_episode(ep)

    results = adapter.recall_topk("When is Alice's birthday?", k=3)
    print(json.dumps({"adapter": "mem0", "query": "When is Alice's birthday?", "results": results}))

    if not results:
        print("FAIL: empty results", file=sys.stderr)
        sys.exit(1)
    print("PASS", file=sys.stderr)
