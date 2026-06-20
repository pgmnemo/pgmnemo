"""Document extraction pipeline — chunk → embed → ingest → (optional LLM) → edges.

This module implements the ``ingest_document()`` method body.
All LLM calls are optional and require explicit ``extraction_model`` from the caller.

Architecture (per research brief DQ-1, DQ-2, R2):
- Extension stays trusted (zero LLM calls in PL/pgSQL).
- Extraction is ALWAYS opt-in — omitting ``extraction_model`` gives the $0 path.
- LLM provider is configurable via litellm (``pip install pgmnemo-client[extract]``).
"""

from __future__ import annotations

import json
import re
import textwrap
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    pass

__all__ = ["chunk_text", "extract_entities_relations", "EXTRACTION_SCHEMA"]

# ---------------------------------------------------------------------------
# Extraction output schema (used as the structured-output spec for litellm)
# ---------------------------------------------------------------------------

EXTRACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "entities": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "type": {"type": "string"},
                    "confidence": {"type": "number"},
                },
                "required": ["name", "type"],
            },
        },
        "relations": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "source": {"type": "string"},
                    "target": {"type": "string"},
                    "relation_type": {"type": "string"},
                    "confidence": {"type": "number"},
                },
                "required": ["source", "target", "relation_type"],
            },
        },
    },
    "required": ["entities", "relations"],
}

_EXTRACTION_SYSTEM = textwrap.dedent("""\
    You are a knowledge-graph extraction assistant.
    Given a text chunk, extract:
    1. Named entities (concepts, tools, methods, errors, components).
    2. Typed relations between entities.

    Respond ONLY with valid JSON matching this schema:
    {"entities": [{"name": str, "type": str, "confidence": 0.0-1.0}],
     "relations": [{"source": str, "target": str,
                    "relation_type": str, "confidence": 0.0-1.0}]}

    confidence below 0.5 means uncertain — omit those.
    relation_type should be a concise verb phrase: "USES", "CAUSES", "SUPERSEDES", etc.
    Return only JSON, no commentary.
""")

# ---------------------------------------------------------------------------
# Text chunking
# ---------------------------------------------------------------------------

_PARA_SEP = re.compile(r"\n{2,}")


def chunk_text(text: str, max_chars: int = 1500, overlap: int = 150) -> list[str]:
    """Split *text* into overlapping chunks ≤ *max_chars* characters.

    Tries paragraph boundaries first; falls back to hard splits.
    Overlap ensures entity mentions near chunk boundaries are captured.

    Parameters
    ----------
    text: str
        Source text (plain text or Markdown).
    max_chars: int
        Soft upper bound per chunk. A single paragraph exceeding this
        is hard-split at word boundaries.
    overlap: int
        Number of characters to repeat between consecutive chunks.

    Returns
    -------
    list[str]
        Non-empty chunks (empty strings stripped).
    """
    if not text:
        return []
    text = text.strip()

    # Split into paragraphs
    paras = [p.strip() for p in _PARA_SEP.split(text) if p.strip()]

    chunks: list[str] = []
    current = ""

    for para in paras:
        if len(para) > max_chars:
            # Hard-split long paragraph at word boundaries
            words = para.split()
            line = ""
            for word in words:
                candidate = (line + " " + word).strip()
                if len(candidate) > max_chars and line:
                    chunks.append(line)
                    line = word
                else:
                    line = candidate
            if line:
                para = line

        if current and len(current) + len(para) + 2 > max_chars:
            chunks.append(current)
            # Keep overlap from end of current chunk
            current = current[-overlap:].strip() + "\n\n" + para if overlap else para
        else:
            current = (current + "\n\n" + para).strip() if current else para

    if current:
        chunks.append(current)

    return [c for c in chunks if c.strip()]


# ---------------------------------------------------------------------------
# LLM extraction
# ---------------------------------------------------------------------------

def extract_entities_relations(
    chunk: str,
    *,
    model: str,
    api_key: str | None = None,
    confidence_threshold: float = 0.5,
    extra_kwargs: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Call *model* via litellm to extract entities and relations from *chunk*.

    Requires ``pip install pgmnemo-client[extract]`` (litellm dependency).

    Parameters
    ----------
    chunk: str
        A single text chunk from ``chunk_text()``.
    model: str
        litellm model identifier, e.g. ``"claude-haiku-3-5"``,
        ``"gpt-4o-mini"``, ``"ollama/llama3"``.
    api_key: str | None
        API key passed directly to litellm (optional; falls back to env vars).
    confidence_threshold: float
        Items with ``confidence < threshold`` are discarded.
    extra_kwargs: dict | None
        Extra kwargs forwarded to ``litellm.completion()``.

    Returns
    -------
    dict with keys ``"entities"`` and ``"relations"`` (lists of dicts).
    Empty dict on any error — caller decides whether to raise or skip.
    """
    try:
        import litellm  # type: ignore[import]
    except ImportError as exc:
        raise ImportError(
            "LLM extraction requires litellm: pip install 'pgmnemo-client[extract]'"
        ) from exc

    kwargs: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": _EXTRACTION_SYSTEM},
            {"role": "user", "content": chunk},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.0,
    }
    if api_key:
        kwargs["api_key"] = api_key
    if extra_kwargs:
        kwargs.update(extra_kwargs)

    try:
        resp = litellm.completion(**kwargs)
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)
    except Exception:  # noqa: BLE001 — extraction failures are non-fatal
        return {"entities": [], "relations": []}

    # Filter by confidence threshold
    entities = [
        e for e in data.get("entities", [])
        if e.get("confidence", 1.0) >= confidence_threshold
    ]
    relations = [
        r for r in data.get("relations", [])
        if r.get("confidence", 1.0) >= confidence_threshold
    ]
    return {"entities": entities, "relations": relations}
