# pgmnemo — Fundamental Positioning: Multimodal RAG Efficiency
**Date:** 2026-06-05  
**Author:** product_owner (16)  
**Input:** OPEN_DECISIONS_2026-06-05, COPY_DECK_2026-06-05, POSITIONING.md (public), COMPETITIVE_REALITY.md, CASE_STUDY_AGENCY_2026-06-01, WHY_PGMNEMO.md + founder directive 2026-06-05  
**For:** growth_lead (#8818 copy deck), design assembly session, D1 resolution  
**Status:** PROPOSED — founder sign-off required on §4 (Спорное)

---

## §1 — Founder Directive: Что изменилось

До этого документа: growth_lead рекомендовал Option A («The missing retrieval stack for Postgres»). Это Layer-1 safe-posture от REFRAME_2026-06-03 — ясная категория, чёткий ICP. Правильно для infrastructure-first Builder, неправильно для лидирующего фрейма.

Founder directive (2026-06-05): **«Память, которая учится тому, что реально сработало» — фундаментальнее, чем Postgres.** Фундамент нужно выводить к актуальному позиционированию: мы смотрим на ЭФФЕКТИВНОСТЬ мультимодального RAG. Формулировка должна вести этим фундаментом, не инфраструктурным слоем.

Это расшифровывается как: **H1 должен называть outcome-loop + mechanism, не infrastructure entry point.** Postgres остаётся в H2 как механизм, не как рамка.

---

## §2 — Settled Lead-Line

### H1 (первая фраза сайта)

> **Memory that learns from what actually worked.**

Почему это именно этот текст, а не что-то другое:

- **«Memory that learns»** — outcome-level, не инфраструктурный слой. Называет результат: память становится умнее.
- **«from what actually worked»** — фиксирует механизм улучшения: обратная связь из реальных агентских исходов (reinforce()), не из LLM-предсказаний и не из правил.
- Не называет Postgres в H1 — следует директиве founder.
- Не называет competitors' owned axes: не «temporal» (Zep), не «AI memory layer» (Mem0), не «graph-enhanced» (LightRAG).
- Совместимо с safe-posture (Layer-1 «missing retrieval stack» остаётся в S3/S5, не в hero).

### H2 (подзаголовок, первый) — Механизм + Эффективность

> **Single-plan fusion across vector, BM25, graph, and metadata — inside your existing Postgres. Zero LLM cost per write. Confidence rises when memory actually helped.**

Разбивка:

| Фраза | Что делает |
|---|---|
| «Single-plan fusion across vector, BM25, graph, and metadata» | Называет мультимодальный RAG явно — четыре канала, не один; структурный moat |
| «inside your existing Postgres» | Инфраструктурный якорь — появляется как следствие, не заголовок |
| «Zero LLM cost per write» | Экономическая эффективность — убивает сравнение с Mem0/Zep/LightRAG |
| «Confidence rises when memory actually helped» | Замыкает loop назад в H1: вот КАК она учится — match_confidence + reinforce() |

### H2 (подзаголовок, второй — альтернатива, короче)

> **Four retrieval channels in one SQL plan. No new service. Memory that improves every time it's right.**

Если дизайн требует более короткого sub — эта версия компактнее.

---

## §3 — Опорный нарратив (3-5 тезисов)

Этот нарратив — то, на что growth_lead ложит копирайт сайта (S3–S6). Каждый тезис — самостоятельный утверждающий блок.

---

### Тезис 1 — Проблема: статичный RAG не компаундирует

Большинство RAG-решений — это склад, не петля. Память хранит то, что в неё положили, возвращает ближайшее по вектору, но не улучшается от результатов. Агент, решивший задачу в прошлом месяце, решает её заново в следующем. Флот движется, но не учится.

**Следствие:** без feedback loop из реальных исходов память — дорогой кэш, а не стратегический актив.

*Используется в:* S3 (The Problem), intro-copy

---

### Тезис 2 — Механизм: single-plan multimodal fusion

pgmnemo ранжирует через четыре канала в одном SQL query plan — HNSW-векторы (pgvector), BM25 full-text (tsvector/GIN), graph-edge proximity (BFS по mem_edge), JSONB metadata pushdown. PostgreSQL optimizer управляет join, filter, sort. Вы вызываете одну функцию.

Это единственный механизм, при котором «мультимодальная RAG-эффективность» не означает три сервиса с тремя схемами синхронизации. Один план — один EXPLAIN.

**Почему это moat**: Apache AGE + pgvector + JSONB ручной сборкой дают те же каналы, но не один план — нет joint optimizer, нет единой точки regression-тестирования.

*Используется в:* S4 (How It Works), S5 (Why), comparison table

---

### Тезис 3 — Обратная связь: память, которая учится от исходов

`reinforce(lesson_id, 'success')` повышает confidence; `reinforce(lesson_id, 'failure')` — снижает. `recall_hybrid()` возвращает `match_confidence [0,1]`. Хорошие уроки всплывают в следующих recall, слабые — тонут.

Это не LLM-driven contradiction detection (Zep) и не entity extraction (Mem0). Это grading by results: память оценивается реальными агентскими исходами, не моделью.

**Прямой доказательный якорь:** Agency production fleet, ~1000 runs/week, −68% turns на runs где recall сработал. Память учится потому что обратная связь реальная.

*Используется в:* S5 (Why), case study callout, proof strip

---

### Тезис 4 — Экономическая эффективность: $0 на write

Ingest = SQL constraint check + indexed INSERT. Zero model API call. Конкуренты:
- Mem0: ~$0.17 / 1 000 writes (GPT-3.5-mini fact extraction)
- Zep: ~$0.36 / 1 000 writes (LLM contradiction detection)
- LightRAG: LLM graph extraction per document — seconds to minutes per batch

Высокочастотная агентская память (1 000+ runs/week) экономически нежизнеспособна при per-write LLM cost. pgmnemo — единственный вариант с $0 write path.

**Claim freeze статус:** D3-approved.

*Используется в:* S5 (Why), comparison table, D4/LightRAG callout

---

### Тезис 5 — Token-economy recall

`navigate_locate()` возвращает ранжированные IDs в рамках character budget. `navigate_expand()` достаёт full content + graph neighbors только для выбранных IDs. Агент получает ровно столько текста, сколько нужно, — не всё что выше threshold.

Это второй уровень эффективности: не только «правильные факты», но и «правильный объём в context window».

*Используется в:* S4 (How It Works), S5 (Why), token-economy callout

---

## §4 — Спорное: Что НЕ хедлайнить сейчас + требует founder sign-off

### Явно НЕ в headline на текущем этапе

| Что | Почему НЕ сейчас | Когда можно |
|---|---|---|
| **Graph-first / «graph recall advantage»** | Gate G1 не пройден: graph recall advantage над single-channel baseline не подтверждён на достаточном корпусе. Graph присутствует в product как один из четырёх каналов, но не как дифференцирующий hero. | После Gate G1 (graph recall + 7.7pp lift на turn-level LoCoMo) |
| **Temporal memory / temporal moat** | Competitor-owned axis: Zep = temporal. Наши bitemporal фичи (t_valid_from/t_valid_to, as_of) существуют, но позиционировать через временну́ю память — значит играть на чужом поле. | Никогда как hero; только как таблица feature-сравнения |
| **«Beats NaiveRAG / BM25 baseline на quality»** | Прямо противоположно факту: BM25 baseline (0.982) обгоняет нас на LongMemEval (0.9604). COMPETITIVE_REALITY.md §1.2. Нельзя. | Никогда пока gap не закрыт |
| **«Enterprise customers»** | Pre-enterprise; единственный named external adopter = agentplatform.ru (consent pending D2a) | После минимум 3 named adopters |
| **Benchmark comparison vs Mem0/Zep/MAGMA** | Разные objectives, разные датасеты — apples-to-oranges (COMPETITIVE_REALITY.md §1.3) | Никогда без fair head-to-head на идентичном датасете |

---

### D1: Разрешение спора Hero Line

**Текущий статус от growth_lead:** Option A recommended («The missing retrieval stack for Postgres»).

**Founder directive (2026-06-05):** фундамент — outcome loop, не infra layer.

**Предлагаемое разрешение (PO):**

Не A, не B. **Synthesis C:**

- **H1** = founder's fundamental: «Memory that learns from what actually worked.»  
- **H2** = structural mechanism + efficiency: «Single-plan fusion...» (§2 выше)
- **Option A («missing retrieval stack»)** сохраняется в S3/S5 как narrative anchor для Postgres-native ICP, но перестаёт быть первой фразой.
- **Option B («agent memory that learns»)** стала H1 — но не «agent memory» (Mem0-owned), а «Memory that learns from what actually worked» (outcome-grounded, не category-generic).

**Вопрос фаундеру:**

> Синтез C принят? Если нет — укажите: (а) точный H1, (б) нужен ли «one SQL plan» в H2 или заменить на что-то менее infra-звучащее.

---

### D4: 49x LightRAG ingestion claim

Growth_lead в OPEN_DECISIONS просит подтвердить источник и методологию 49x числа перед hero placement.

PO позиция: **не блокировать copy deck этим числом на старте сайта.** Включить в S5/S6 как supporting claim с точным framing:

> «Ingest in milliseconds — not minutes. LightRAG builds a knowledge graph via LLM extraction on every document. pgmnemo ingests via SQL INSERT. [Gap: ~49x at N-doc corpus size — [FREEZE NEEDED]]»

Founder action: подтвердить (а) источник, (б) corpus size, (в) cleared for publication.

---

## §5 — Передаточный пакет для growth_lead (#8818)

**Что settled и передаётся в copy deck:**

1. H1: «Memory that learns from what actually worked.»
2. H2: «Single-plan fusion across vector, BM25, graph, and metadata — inside your existing Postgres. Zero LLM cost per write. Confidence rises when memory actually helped.»
3. Нарратив §3 (5 тезисов) как scaffolding для S3–S6.
4. NOT-headline list (§4 таблица): graph-first, temporal, quality-vs-baseline, enterprise claims.

**Что ещё blocked:**

- D1 Synthesis C → founder sign-off (unlock: можно писать copy deck с Synthesis C, отмечать как [PENDING FOUNDER OK D1])
- D2a agentplatform.ru consent → proof strip
- D2b −68% turns clearance → stat chip
- D4 49x source → S6 claim freeze

---

*product_owner (16) · 2026-06-05 · Agency private (site-internal/.gitignore)*
