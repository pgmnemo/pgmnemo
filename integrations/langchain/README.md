# pgmnemo-langchain

LangChain `BaseRetriever` adapter for [pgmnemo](https://github.com/pgmnemo/pgmnemo) — a PostgreSQL-native multi-agent memory substrate.

## Install

```bash
pip install -e .
```

Or from PyPI (once published):

```bash
pip install pgmnemo-langchain
```

## Usage

```python
from pgmnemo_langchain import PgmnemoRetriever

# Any callable that returns a list[float] of length 1024
def embed(text: str) -> list[float]:
    import openai
    resp = openai.embeddings.create(model="text-embedding-3-large", input=text)
    return resp.data[0].embedding

retriever = PgmnemoRetriever(
    conn_str="postgresql://user:password@localhost:5432/mydb",
    role="backend-agent",
    project_id=42,
    top_k=5,
    embedding_fn=embed,
)

docs = retriever.invoke("How should we handle retries in the ingest pipeline?")
for doc in docs:
    print(doc.metadata["topic"], "—", doc.page_content[:120])
```

## Requirements

- PostgreSQL 14+ with `pgvector` and the `pgmnemo` extension installed
- Python 3.10+
