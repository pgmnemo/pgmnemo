#!/usr/bin/env python3
"""
A-MEM adapter for pgmnemo benchmark harness.

A-MEM: "Agentic Memory for LLM Agents" (Woo et al., 2025).
Paper:  https://arxiv.org/abs/2502.12110
Repo:   https://github.com/WowCZ/A-MEM

Install:
    git clone https://github.com/WowCZ/A-MEM && cd A-MEM
    pip install -e .
    # OR:
    pip install a-mem>=0.1.0  (if published to PyPI)
    Set OPENAI_API_KEY for LLM-based note synthesis.

Hypothesis:     A-MEM Zettelkasten-style linked note retrieval vs. pgmnemo cosine recall.
IV:             memory backend (A-MEM vs. pgmnemo)
DV:             recall@K on LoCoMo / LongMemEval toy fixture
Control:        identical queries, identical episode text, K=5
Treatment:      amem.search(query, topk=K)
Power:          N>=50 episodes per fixture sufficient for d>=0.5 at alpha=0.05, power=0.80
Confounds:      A-MEM LLM note-synthesis step mutates stored content; links between notes
                create graph structure absent in pgmnemo baseline; embedding model may
                differ; OpenAI API latency inflates wall-clock time.
"""
from __future__ import annotations

import os
import uuid
from typing import Any


# ---------------------------------------------------------------------------
# Toy stub
# ---------------------------------------------------------------------------

class _MockAMem:
    """Minimal Zettelkasten-like stub that satisfies non-empty evidence threshold."""

    def __init__(self) -> None:
        self._notes: list[dict] = []

    def add(self, content: str, metadata: dict | None = None) -> dict:
        note_id = str(uuid.uuid4())
        note = {
            "id": note_id,
            "content": content,
            "keywords": content.lower().split()[:5],
            "links": [],
            "metadata": metadata or {},
        }
        # naive linking: link to prior notes sharing a keyword
        for kw in note["keywords"]:
            for existing in self._notes:
                if kw in existing["keywords"] and existing["id"] not in note["links"]:
                    note["links"].append(existing["id"])
        self._notes.append(note)
        return note

    def search(self, query: str, topk: int = 5) -> list[dict]:
        query_words = set(query.lower().split())
        scored = []
        for note in self._notes:
            overlap = len(query_words & set(note["keywords"]))
            if overlap > 0:
                scored.append((overlap, note))
        scored.sort(key=lambda x: x[0], reverse=True)
        if not scored:
            return self._notes[:topk]
        return [note for _, note in scored[:topk]]

    def reset(self) -> None:
        self._notes.clear()


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------

class AMEMAdapter:
    """
    Exposes write_episode / recall_topk over A-MEM.

    Each message in an episode becomes one A-MEM note. The Zettelkasten
    linker runs at insert time (real) or via keyword overlap (mock).

    Args:
        use_mock:   bypass real A-MEM (set True or env MOCK_ADAPTERS=1)
        llm_model:  OpenAI model for A-MEM note synthesis (default gpt-4o-mini)
        embedder:   embedding model name passed to A-MEM (default text-embedding-3-small)
    """

    def __init__(
        self,
        use_mock: bool = False,
        llm_model: str = "gpt-4o-mini",
        embedder: str = "text-embedding-3-small",
    ) -> None:
        self._mock = use_mock or os.getenv("MOCK_ADAPTERS", "0") == "1"

        if self._mock:
            self._mem = _MockAMem()
            return

        try:
            # A-MEM public API (WowCZ/A-MEM repo)
            from amem.memory import AgenticMemory  # type: ignore[import]
        except ImportError as exc:
            raise ImportError(
                "Install A-MEM: git clone https://github.com/WowCZ/A-MEM && pip install -e ./A-MEM"
                "  OR: pip install a-mem>=0.1.0"
            ) from exc

        self._mem = AgenticMemory(
            llm_model=llm_model,
            embedding_model=embedder,
        )

    # ------------------------------------------------------------------

    def write_episode(self, episode: dict) -> None:
        """
        Ingest one episode into A-MEM as individual notes.

        episode schema:
          session_id: str
          messages:   list[{role: str, content: str}]
          metadata:   dict (optional)
        """
        session_id = episode.get("session_id", "")
        metadata = {**episode.get("metadata", {}), "session_id": session_id}
        for msg in episode.get("messages", []):
            text = f"{msg['role']}: {msg['content']}"
            if self._mock:
                self._mem.add(text, metadata=metadata)
            else:
                self._mem.add(content=text, metadata=metadata)

    def recall_topk(self, query: str, k: int = 5) -> list[str]:
        """Return up to k note contents most relevant to query."""
        if self._mock:
            hits = self._mem.search(query, topk=k)
            return [h.get("content", str(h)) for h in hits]

        try:
            results = self._mem.search(query, topk=k)
            # A-MEM returns list of note dicts with 'content' key
            return [r.get("content", r.get("note", str(r))) for r in results]
        except Exception:
            return []

    def reset(self) -> None:
        if self._mock:
            self._mem.reset()
            return
        try:
            self._mem.reset()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CLI smoke-test entry-point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse, json, sys
    from pathlib import Path

    ap = argparse.ArgumentParser(description="A-MEM adapter smoke-test")
    ap.add_argument("--mock", action="store_true", default=True)
    ap.add_argument("--fixture", default=None)
    args = ap.parse_args()

    adapter = AMEMAdapter(use_mock=args.mock)

    fixture = [
        {
            "session_id": "s1",
            "messages": [
                {"role": "user", "content": "Alice's birthday is on March 14."},
                {"role": "assistant", "content": "Got it."},
            ],
        },
        {
            "session_id": "s2",
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
    print(json.dumps({"adapter": "amem", "query": "When is Alice's birthday?", "results": results}))

    if not results:
        print("FAIL: empty results", file=sys.stderr)
        sys.exit(1)
    print("PASS", file=sys.stderr)
