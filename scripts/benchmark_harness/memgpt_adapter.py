#!/usr/bin/env python3
"""
MemGPT / Letta adapter for pgmnemo benchmark harness.

Letta is the production name for MemGPT (v0.6+).
Install:
    pip install letta-client>=0.1.0
    # OR self-hosted server:
    pip install letta>=0.6.0
    letta server  # starts on http://localhost:8283

For Letta Cloud: set LETTA_API_KEY env var.
For self-hosted:  set LETTA_BASE_URL=http://localhost:8283

Hypothesis:     Letta/MemGPT archival-memory retrieval vs. pgmnemo cosine recall.
IV:             memory backend (Letta vs. pgmnemo)
DV:             recall@K on LoCoMo / LongMemEval toy fixture
Control:        identical queries, identical episode text, K=5
Treatment:      agent.archival_memory_search() or client.agents.archival.list()
Power:          N>=50 episodes per fixture sufficient for d>=0.5 at alpha=0.05, power=0.80
Confounds:      Letta uses LLM-driven memory consolidation (MemGPT architecture);
                results depend on LLM used for archival insert; latency much higher
                than embedding-only retrieval.
"""
from __future__ import annotations

import os
import uuid
from typing import Any


# ---------------------------------------------------------------------------
# Toy stub
# ---------------------------------------------------------------------------

class _MockLetta:
    def __init__(self) -> None:
        self._archival: list[dict] = []

    def insert(self, text: str, metadata: dict | None = None) -> None:
        self._archival.append({"text": text, "metadata": metadata or {}})

    def search(self, query: str, k: int = 5) -> list[dict]:
        hits = [
            a for a in self._archival
            if any(w in a["text"].lower() for w in query.lower().split())
        ]
        return (hits or self._archival)[:k]

    def reset(self) -> None:
        self._archival.clear()


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------

class MemGPTAdapter:
    """
    Exposes write_episode / recall_topk over Letta/MemGPT archival memory.

    Creates one Letta agent per adapter instance; episodes are inserted into
    archival memory as plain text passages (role: content).

    Args:
        agent_name:  Letta agent name (created if absent)
        use_mock:    bypass real Letta (set True or env MOCK_ADAPTERS=1)
        base_url:    Letta server URL (default env LETTA_BASE_URL)
        api_key:     Letta Cloud key (default env LETTA_API_KEY)
    """

    def __init__(
        self,
        agent_name: str | None = None,
        use_mock: bool = False,
        base_url: str | None = None,
        api_key: str | None = None,
    ) -> None:
        self.agent_name = agent_name or f"bench_agent_{uuid.uuid4().hex[:6]}"
        self._mock = use_mock or os.getenv("MOCK_ADAPTERS", "0") == "1"

        if self._mock:
            self._store = _MockLetta()
            return

        _base_url = base_url or os.getenv("LETTA_BASE_URL", "http://localhost:8283")
        _api_key = api_key or os.getenv("LETTA_API_KEY", "")

        try:
            from letta_client import Letta  # type: ignore[import]
        except ImportError:
            try:
                from letta import create_client  # type: ignore[import]
                self._client = create_client(base_url=_base_url)
                self._agent_id = self._get_or_create_agent_v06()
                self._sdk = "v06"
                return
            except ImportError as exc:
                raise ImportError("pip install letta>=0.6.0 OR pip install letta-client>=0.1.0") from exc

        # letta-client (newer REST client)
        self._client = Letta(base_url=_base_url, token=_api_key or None)
        self._agent_id = self._get_or_create_agent_client()
        self._sdk = "client"

    # ------------------------------------------------------------------

    def _get_or_create_agent_v06(self) -> str:
        from letta import AgentState  # type: ignore[import]
        agents = self._client.list_agents()
        for a in agents:
            if getattr(a, "name", None) == self.agent_name:
                return a.id
        agent = self._client.create_agent(name=self.agent_name)
        return agent.id

    def _get_or_create_agent_client(self) -> str:
        agents = self._client.agents.list()
        for a in agents:
            if getattr(a, "name", None) == self.agent_name:
                return a.id
        agent = self._client.agents.create(name=self.agent_name)
        return agent.id

    # ------------------------------------------------------------------

    def write_episode(self, episode: dict) -> None:
        """
        Ingest one episode into Letta archival memory.

        episode schema:
          session_id: str
          messages:   list[{role: str, content: str}]
          metadata:   dict (optional)
        """
        messages = episode.get("messages", [])
        session_id = episode.get("session_id", "")
        for msg in messages:
            text = f"[{session_id}] {msg['role']}: {msg['content']}"
            if self._mock:
                self._store.insert(text, metadata=episode.get("metadata"))
            else:
                self._insert_archival(text)

    def _insert_archival(self, text: str) -> None:
        if self._sdk == "client":
            self._client.agents.archival.insert(
                agent_id=self._agent_id, content=text
            )
        else:
            self._client.insert_archival_memory(self._agent_id, text)

    def recall_topk(self, query: str, k: int = 5) -> list[str]:
        """Return up to k archival memory passages most relevant to query."""
        if self._mock:
            return [h["text"] for h in self._store.search(query, k)]

        try:
            if self._sdk == "client":
                results = self._client.agents.archival.list(
                    agent_id=self._agent_id, query=query, limit=k
                )
            else:
                results = self._client.get_archival_memory(
                    self._agent_id, query=query, start=0, count=k
                )
            return [getattr(r, "text", str(r)) for r in results]
        except Exception:
            return []

    def reset(self) -> None:
        if self._mock:
            self._store.reset()
            return
        try:
            if self._sdk == "client":
                passages = self._client.agents.archival.list(agent_id=self._agent_id)
                for p in passages:
                    self._client.agents.archival.delete(
                        agent_id=self._agent_id, memory_id=p.id
                    )
            else:
                self._client.delete_agent(self._agent_id)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CLI smoke-test entry-point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse, json, sys
    from pathlib import Path

    ap = argparse.ArgumentParser(description="MemGPT/Letta adapter smoke-test")
    ap.add_argument("--mock", action="store_true", default=True)
    ap.add_argument("--fixture", default=None)
    args = ap.parse_args()

    adapter = MemGPTAdapter(use_mock=args.mock)

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
    print(json.dumps({"adapter": "memgpt", "query": "When is Alice's birthday?", "results": results}))

    if not results:
        print("FAIL: empty results", file=sys.stderr)
        sys.exit(1)
    print("PASS", file=sys.stderr)
