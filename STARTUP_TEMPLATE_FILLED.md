# pgmnemo — Заполненный Стартап-Шаблон

**Дата:** 2026-05-19
**Продукт:** pgmnemo (Postgres extension: write-time provenance gate for citation-grounded agent memory)
**Заполнено:** TL Karpov (inline после 3-го no-op эскалейта #6398; источники: SYNTHESIS_VC_PGMNEMO_2026-05-17.md RATIFIED + POS-WEDGE/POS-MARKET/POS-DEFENSE/POS-VC/POS-DATA/POS-MENTOR)
**Tagline (LOCKED по SYNTHESIS_VC §3 D1):** *Provenance-enforced memory for agents that must cite their sources.*

---

## Sheet 1: Актуальность и Уникальность

### Концепция стартап-идеи

| Параметр | Значение |
|---|---|
| Наименование проекта | **pgmnemo** |
| Краткое описание продукта/услуги | Provenance-enforced memory для citation-grounded AI-агентов. Postgres-extension: `CREATE EXTENSION pgmnemo` в существующий Postgres-инстанс. `ingest()` отвергается RLS-политикой на уровне БД-конструкции если нет валидного `commit_sha`/`artifact_hash`. Никакого нового сервиса, никаких LLM-вызовов на запись, никакого ухода данных за пределы инфраструктуры. |
| Команда проекта | Founder/maintainer (single-maintainer OSS — отмечено честно в POS-DATA §1.2 и POSITIONING). Agency (project_id=20 / external Architecture C consumer) — first external production user. Ранний community contribution через ICSE-SEIP paper preparation. |

### Оценка актуальности и уникальность идеи

| Критерий | Значение |
|---|---|
| Проблема/потребность | Agent memory writes без provenance-проверки попадают в БД, кумулируются, всплывают как retrieval results. Post-hoc audit logs фиксируют что произошло — но не блокируют. Для compliance-bound агентов (HIPAA §164.312, SOC 2, FINRA, FDA 21 CFR Part 11) это hard legal liability. Острота: 5/5 для regulated AI, 4/5 для customer support, 3/5 для RAG enterprise. |
| Тренды и своевременность | (a) AI agent deployment взрывается в 2025-2026 — Mem0 186M API calls/mo at 30% MoM; Letta 1M+ agents в проде у Bilt. (b) Regulated industries (healthcare/legal/finance) adopting agents и сталкиваются с audit-trail mandate. (c) PostgreSQL + pgvector становится de-facto стандартом для production agent memory (Aurora, RDS, Supabase). pgmnemo сидит на пересечении этих трёх трендов. |
| Статистика | Mem0: 186M API calls/мес, 80K+ developers (2025). Letta: 1M+ agents у одного клиента (Bilt). Постоянное растущее давление regulatory: HIPAA penalties up to $1.5M/year; SOC 2 audit failures stop enterprise sales. Конкретный SAM для pgmnemo (citation-grounded × Postgres-using): ~$720M к 2028 (POS-WEDGE §3, derived from IDC). |
| Регуляторные/социальные факторы | **Стимулы:** HIPAA §164.312 (audit controls), SOC 2 Type II audit trails, FINRA recordkeeping, FDA 21 CFR Part 11 для clinical trials, EU AI Act (high-risk AI traceability). **Барьеры:** Apache 2.0 license устраняет legal friction; нет export-control implications; нет PII residency (data остаётся в клиентском Postgres). |
| Новизна/оригинальность | Уникальный structural moat подтверждён единогласно 5/5 WG positions: **никто из конкурентов** (Mem0/Zep/Letta/Constructive AgenticDB) не имеет write-time provenance gate на уровне DB-конструкции. Все остальные = post-hoc audit logs (которые регулятор не принимает как "preventive control"). |
| Сложность копирования | Mem0/Zep/Letta — SaaS Python services, у них provenance enforcement на application layer; копировать = переписать backend от data layer вверх (12-18 месяцев минимум — POS-DEFENSE §2 scenario b). Constructive AgenticDB — ближайший architectural peer (Postgres extension, MIT, pgvector/HNSW), но без gate. Anthropic не пойдёт в Postgres infra business (POS-MENTOR §4). |
| Потенциал масштабирования | Бесплатная OSS distribution через PGXN + GitHub. Каждый Postgres-running citation-grounded agent project = potential install (~5 мин до первого `pgmnemo.ingest()`). Enterprise revenue path = dual-license commercial tier (audit-mode SIEM export, multi-tenant provenance dashboard) при v1.0 gate (≥3 external case studies, Q4 2026). |
| Социальная/экологическая значимость | (a) Снижение AI-hallucination риска в regulated industries (медицина, право, финансы) = меньше реального вреда от LLM ошибок. (b) Zero-LLM-per-write design = drastically меньше compute/energy на agent memory operations vs Mem0 (~$0.17/1K writes) и Zep (~$0.36/1K). (c) OSS Apache 2.0 = доступность для академических исследований и развивающихся рынков. |

---

## Sheet 2: Проблема и решение

| № | Проблема | Описание проблемы | Корневая причина | Текущее решение/альтернатива и её недостатки | Решение стартапа (описание) | Ключевые преимущества решения | Рекомендации по улучшению |
|---|---|---|---|---|---|---|---|
| 1 | **Hallucinated/stale agent memory без audit trail** (S4 medical/legal/finance compliance) | AI agent пишет в память сгенерированное LLM утверждение без traceability к исходному документу/записи. HIPAA/SOC 2 audit запрашивает provenance — её нет. Compliance failure. | Mem0/Zep пишут что LLM extracted; `metadata=` это post-hoc log, не write-time veto. У Letta `core_memory_append` безусловный. | Mem0 enterprise + custom audit layer ($110K-$250K year 1 + DPA для HIPAA, см. POS-DEFENSE §3 path iii). Не закрывает требование "никогда не записывать без provenance". | pgmnemo's RLS policy + CHECK constraint в Postgres executor: `INSERT` без `artifact_hash` отвергается до того как row попадает в heap. Невозможно обойти из application layer. | (a) Архитектурное (не feature) различие. (b) Self-hosted в client RDS/Aurora — PHI не покидает client infrastructure. (c) Audit log = "rejected writes" = preventive control в compliance терминах. | Pilot с 1-2 healthcare AI vendors (Epic competitor, clinical AI startup) к v0.6.0 для public case study + HIPAA BAA готовности. |
| 2 | **Stale belief в customer support agents → wrong SLA response** (S2) | Support AI запомнил resolution policy из старого ticket'а; через 6 месяцев восстановил эту "правду" для нового похожего ticket'а, дав wrong policy answer. SLA breach, customer escalation, CX lead heat. | Ticket-grounded memory без write-time citation = orphan facts. Текущие фреймворки (Zendesk AI, Intercom Fin) делают post-hoc retrieval log без write-time anchoring. | Application-level "memory cleanup" jobs (срок жизни N дней, manual purge). Не блокирует momentum stale fact в production retrieval окно. | `ticket_id` = artifact_hash. `pgmnemo.ingest(content, artifact_hash=ticket_id)` отвергается RLS если ticket_id не зарегистрирован. Memory write anchored к Zendesk ticket lifecycle. | (a) Reactive trigger (после первого CX incident) → запрос на pgmnemo = легко sold. (b) Postgres уже у customer (Zendesk backend = PG). (c) Setup <5 мин: `CREATE EXTENSION pgmnemo`. | Outbound к 30 top Zendesk-AI/Intercom-Fin shops к 2026-06-15. Template 3 в POS-MARKET §3. |
| 3 | **Hallucinated code memory у software dev agents** (S1 — Agency dogfood + Cursor/Copilot Workspace ICP) | Code review/PR-summarization agent запомнил belief про функцию по старому коду; функция переписана; agent рестрорит stale belief в новом PR review. Wrong review, dev confusion. | Commit-grounded memory без commit_sha anchoring = orphan code-facts. Текущие code-AI tools (Cursor, Copilot Workspace) не имеют commit-anchored memory layer. | Application-level cleanup "сбросить память на каждый push" = убийство whole-codebase context. Trade-off recall vs freshness. | `commit_sha` = native artifact_hash. pgmnemo `ingest()` отвергается без valid commit. `t_valid_to` trigger (v0.5.0) делает старые facts невидимыми после refactor commit. | (a) Низкий ARPU но free OSS distribution = wedge для testimonials + 500 GitHub stars (POS-DATA §2). (b) Agency = production reference. (c) Bitemporality v0.5.0 differentiates от Cursor's stateless memory. | First-10 customers: target 3 indie code-agent startups (5-25 eng) к 2026-06-15. Open GitHub issues в LlamaIndex/LangChain memory threads. |

---

## Sheet 3: Ценностное предложение и целевая аудитория

| № | Целевая аудитория | Описание сегмента | Ключевые проблемы/потребности | Ценностное предложение | Уникальные преимущества/отстройка | Каналы коммуникации и продаж | Рекомендации по доработке |
|---|---|---|---|---|---|---|---|
| 1 | **S1 — Software dev agents** (GitHub Copilot Workspace, Cursor, Agency itself) | 5-25 eng startups + indie devs, Platform Eng / CTO / Solo Dev buyer persona. Уже на Postgres. | Stale code beliefs, hallucinated functions, commit_sha audit trail для CI/CD compliance | "commit_sha как natural artifact_hash — pgmnemo gate работает из коробки на любом git-backed agent" | Native commit-grounding; Agency = production reference; zero new services | Postgres Weekly, PGConf, GitHub issue cold outreach в LlamaIndex/LangChain memory threads | Wedge сегмент: distribution + testimonials, не revenue. Цель: 500 GitHub stars к 2026-09. |
| 2 | **S2 — Customer support / ticketing agents** (Zendesk AI, Intercom Fin, Freshdesk Freddy) | 50-200 eng B2B SaaS, VP CX / Platform Eng / Compliance Officer. CCPA/GDPR mandates. | Stale policy beliefs → wrong SLA, audit-trail для customer disputes | "ticket_id-grounded memory, audit trail enforced at DB layer" | Compliance-grade SLA + GDPR Article 28 compatible (self-hosted) | Direct cold email (POS-MARKET §3 Template 3), Postgres ecosystem | **First revenue сегмент.** Target 3 customers $12-24K/year = $36-72K ARR к 2026-09. |
| 3 | **S3 — Document-grounded RAG agents** (Notion AI, Confluence AI, Guru) | 30-150 eng enterprise knowledge mgmt, Head of AI / Knowledge Ops Lead | Hallucination from unversioned source docs, page_revision tracking | "document_hash + page_revision_id в каждой memory entry" | Bitemporality v0.5.0 для outdated-doc detection | LlamaIndex/LangChain integration, conference talks (RAG sessions) | Secondary — открыть после S1+S2 case studies. |
| 4 | **S4 — Regulated AI** (clinical decision support, compliance AI, legal contract review) | 15-100 eng healthcare/legal/fintech, CISO / Compliance Officer / CMIO. HIPAA/SOC 2/FINRA hard mandate. | Audit-trail = legal requirement, write-time provenance = preventive control | "patient_record_id / case_id / filing_id как DB-enforced provenance — single architectural answer для всего compliance perimeter" | Self-hosted = data residency, RLS-evaluated = bypass-proof, zero LLM cost per write | HIMSS community, AngelList/Crunchbase outreach к legal/healthcare AI startups, ICSE-SEIP paper credibility | **High-ARPU сегмент ($50K-$500K/year), 6-12 month sales cycle.** Требует SOC 2 Type II (v1.0 prerequisite). |
| 5 | **S5 — Legal AI** (Clio, Bloomberg Law, Westlaw Edge AI, contract review startups) | 10-50 eng legal-tech, Head of Legal Tech / Senior Partner / CISO. Malpractice risk от stale legal facts. | Citation-anchored memory writes (case_id, filing_id), Bar association audit trails | "Native legal-citation primitive: каждый memory row anchored к citable case/filing" | Audit trail accepts in legal proceedings (chain-of-custody); zero data leak (self-hosted) | Direct cold email (POS-MARKET §3 Template 1), legal-tech conferences | Pilot 1 e-discovery startup к 2026-09 = public case study credibility. |

**Walk-away (НЕ ICP):** S6 — pure conversational agents (ChatGPT memory, Mem0 consumer, Replika), proactive observation agents, personal-assistant chitchat. Gate отвергает каждый их write by design. ~$2.4B TAM = ~60% от total — это Mem0/Letta home turf, не наш.

---

## Sheet 4: Оценка рынка

### Объем рынка

| № | Показатель | Описание | Формула / Источник | Значение |
|---|---|---|---|---|
| 1 | **TAM** (Total Addressable Market) | Global LLM-agent memory spend by 2028 | IDC AI Software Forecast 2023-2027 (~$220B by 2028) × 10% agent infrastructure × 20% memory layer | **~$4B** (agent memory broadly defined) |
| 2 | **SAM** (Serviceable Addressable Market) | Citation-grounded × Postgres-using subset | TAM × 40% (citation-grounded — S1-S5 segments) × 45% (Postgres market share in dev tooling / SaaS / startups, derived from DB-Engines Q1 2026) | **~$720M by 2028** |
| 3 | **SOM** (Serviceable Obtainable Market) | 3-year realistic share given OSS distribution | Conservative ($0 ARR) / Base ($180K ARR @ 15 contracts × $12K/yr) / Bull ($1.4M ARR @ 30 enterprise + 3 high-ARPU regulated) | **$180K-$1.4M ARR by 2028** (base-to-bull) |

### Ключевые параметры оценки рынка

| № | Параметр рынка | Значение |
|---|---|---|
| 1 | **Темпы роста** | AI agent infrastructure: ~31% CAGR (IDC). Agent memory specifically — нет analyst line item; proxy через Mem0 30% MoM growth. К 2028 ожидаемый размер $4-5B. |
| 2 | **Основные сегменты** | S1 software dev (low ARPU, high distribution), S2 customer support (first revenue), S3 RAG enterprise (secondary), S4 regulated AI (high ARPU $50-500K, 6-12mo cycle), S5 legal AI (high ARPU, malpractice driver) |
| 3 | **География** | Primary: US enterprise (HIPAA, SOC 2, FINRA driven). Secondary: EU (GDPR Article 28 — self-hosted preference). Tertiary: regulated EM markets (banking, healthcare). |
| 4 | **Тренды и драйверы** | (a) AI Act EU + similar in US ⇒ growing AI traceability mandate. (b) Postgres-as-platform thesis (Supabase, Neon, EDB). (c) Self-hosted AI infra resurgence (PHI/PII data residency).  (d) Mem0/Letta доказали category — pgmnemo defines primitive. |
| 5 | **Конкуренты** | **Mem0** (186M API calls/mo, SaaS, no gate). **Zep + Graphiti** (knowledge-graph, episode provenance descriptive only). **Letta** (Aurora-backed, conversational, `core_memory_append` unconditional). **Constructive AgenticDB** (closest architectural peer: PG extension MIT, без gate). **MAGMA** (historical context, retired). См. POSITIONING.md competitor matrix. |
| 6 | **Барьеры для входа** | Технические: deep PostgreSQL RLS expertise (POS-DEFENSE §3 path i: ~$240-360K build cost in-house). Compliance: SOC 2 Type II audit (~$50-100K + 6 months). Operational: 24/7 OSS maintainer commitment to bus-factor mitigation. License: Apache 2.0 = zero adoption friction, никаких legal blockers. |
| 7 | **Готовность платить** | S1: $0 (OSS expectations). S2: $12-24K/year support contract (proven Elastic/Timescale playbook). S3: $24-36K/year enterprise tier. **S4/S5: $50-500K/year compliance budgets** (HIPAA-bound healthcare, FINRA-bound finance). К Series A нужно ≥3 S4/S5 paying customers. |

---

## Sheet 5: Конкурентный анализ

| № | Критерий | Ваш стартап (pgmnemo) | Конкурент 1 (Mem0) | Конкурент 2 (Zep / Graphiti) |
|---|---|---|---|---|
| 1 | Название компании | pgmnemo (single-maintainer OSS) | Mem0 (Y Combinator backed, $23.9M raised) | Zep AI Inc. (commercial) + Graphiti (OSS) |
| 2 | Сайт / контакты | github.com/pgmnemo/pgmnemo (Apache 2.0) | mem0.ai (SaaS) | getzep.com / github.com/getzep/graphiti |
| 3 | Продукт / услуга | Postgres extension: write-time provenance gate + hybrid recall (vec + BM25 + recency) in-database. Zero LLM cost per write. | Managed agent memory SaaS API. LLM-driven fact extraction (~$0.17 / 1K writes). | Self-hosted Python service + graph DB (Graphiti OSS) или Zep Cloud (managed SaaS, $0.36/1K writes). |
| 4 | Целевая аудитория | Citation-grounded agents — S1-S5 (RAG, support, medical, legal, software dev) | General agent memory incl. conversational. AWS Agent SDK default. 80K+ developers (2025). | Knowledge-graph agent memory. Enterprise tier customers. |
| 5 | Цена | Apache 2.0 free. Future dual-license enterprise tier (v1.0+): audit-mode SIEM export, multi-tenant provenance dashboard. | SaaS pricing not publicly tiered; enterprise contracts estimated $50-150K/year. | Graphiti OSS free. Zep Cloud paid tiers, enterprise unpublished pricing. |
| 6 | Каналы продаж | OSS PGXN + GitHub + cold email (compliance segment). Conference talks. ICSE-SEIP paper. | AWS Marketplace, AWS Agent SDK default integration, mem0.ai signup funnel. | Direct enterprise sales + open-source GitHub adoption funnel. |
| 7 | Каналы продвижения | Postgres Weekly, PGConf, GitHub issue outreach в LlamaIndex/LangChain, Anthropic MCP Registry, academic paper (EMNLP target). | AWS partner ecosystem, TechCrunch coverage, dev influencer marketing. | HackerNews discussions, conference talks, content marketing on memory benchmarks. |
| 8 | Ключевые преимущества | **Write-time gate at DB constraint level** (unique structurally). Zero LLM cost per write. Self-hosted = data residency. Postgres-native (no new services). Honest benchmarks (publishes negative cells). | Scale (186M API calls/mo). Polished managed SaaS DX. AWS distribution. Brand recognition. | Knowledge graph data model. Bitemporal facts native. Mature graph traversal patterns. |
| 9 | Слабые стороны | 1 production user (founder dogfood). 0 paying customers. ICP narrow (excludes 60% TAM = conversational). recall@10 loses to BM25 on LongMemEval (0.933 vs 0.982). | No write-time gate (post-hoc audit only). SaaS data-residency blocker для HIPAA/GDPR. LLM-cost-per-write scales. Reported benchmark integrity disputes (HN). | Bitemporal facts produced by LLM extraction (expensive at scale). No write-time provenance veto. Python service overhead vs in-DB. |
| 10 | Технологии | PostgreSQL 14+ extension, pgvector HNSW, BM25 via tsvector, RLS policies + CHECK constraints, planned bitemporality v0.5.0 (H-07). | Python SDK + cloud backend (architecture not public). GPT-5-mini/gpt-4o-mini for fact extraction. | Python + Neo4j/FalkorDB/Kuzu (Graphiti); pgvector driver "one quarter away" per Zep roadmap. |
| 11 | Команда / экспертиза | Single-maintainer OSS + Agency external production user as first ICSE-SEIP citation. Strong PostgreSQL RLS expertise documented in code. | Multi-person team, Y Combinator backed. Strong AWS partnership. | Established commercial team. Multiple OSS contributors to Graphiti. |
| 12 | Отзывы / репутация | Pre-traction (1 prod user). ICSE-SEIP submission pending. Honest negative-cell benchmark publication (POS-RS-PGM spec). | 80K+ registered devs, 186M+ API calls/mo (2025). AWS exclusive memory provider for Agent SDK. | Established knowledge-graph thought leadership. Some controversy on benchmark integrity (HN 44883133). |

---

## Sheet 6: Lean Canvas (Business Model)

| № | Блок Canvas | Для pgmnemo |
|---|---|---|
| 1 | **Ключевые партнеры** | (a) Anthropic — MCP Registry listing, провенанс-extension proposal в MCP spec до v0.6.0. (b) Supabase / Neon / EDB — Postgres-as-platform ecosystem (potential acquirers per POS-VC §4). (c) AWS via AWS Agent SDK adapter (P1-gated research due 2026-05-30). (d) Academic institutions — ICSE-SEIP paper + university medical AI groups для third-party reproducibility validation. (e) pgpm (Constructive AgenticDB's distribution channel) для channel parity. |
| 2 | **Ключевые виды деятельности** | (a) Extension development (SQL + minor C), bench protocol maintenance, RLS policy correctness audit. (b) Customer development — DISCOVERY_PROTOCOL.md Mom Test interviews (5-8 due 2026-06-15). (c) Compliance documentation (HIPAA BAA ready, SOC 2 prep). (d) Academic paper (EMNLP 2026 submission). (e) GitHub issue outreach в RAG framework memory threads. |
| 3 | **Ключевые ресурсы** | (a) PostgreSQL RLS expertise (single-maintainer, bus-factor risk). (b) Existing codebase Apache 2.0 (50 LOC critical SQL gate, hardened через 4 releases). (c) Agency production corpus (recall@10=0.5745 N=1060, only third-party validation today). (d) ICSE-SEIP submission credibility. (e) Architecture C dogfood relationship с Agency. |
| 4 | **Ценностные предложения** | **Tagline (LOCKED):** *"Provenance-enforced memory for agents that must cite their sources."* Sub: каждый `ingest()` отвергается Postgres executor'ом до commit'а row'а если нет валидного `commit_sha` или `artifact_hash`. Self-hosted, zero LLM cost per write, bypass-proof architecturally (а не feature-level). |
| 5 | **Взаимоотношения с клиентами** | (a) OSS self-service install (PGXN, GitHub). (b) Direct technical email для compliance segment. (c) Future: paid commercial support tier для enterprise customers (v1.0+). (d) Community Discord/Slack — НЕ запускать до v0.6.0 (resource overhead не оправдан pre-adoption). |
| 6 | **Сегменты клиентов** | S1 software dev (wedge, low ARPU), S2 customer support (first revenue, $12-24K/year), S3 RAG enterprise (secondary, $24-36K), **S4 regulated AI ($50-500K/year, primary high-ARPU target после v1.0), S5 legal AI ($50-200K/year)**. Walk-away: S6 conversational. |
| 7 | **Каналы коммуникации и сбыта** | См. POS-MARKET §2 top-5 channels: (1) Postgres ecosystem (PGXN/Postgres Weekly/PGConf), (2) GitHub cold outreach в LlamaIndex/LangChain memory issues, (3) Direct cold email к compliance AI startups, (4) Academic EMNLP 2026 paper, (5) Anthropic MCP Registry. |
| 8 | **Структура издержек** | Year 1: 1 FTE founder/maintainer (≈$120K opportunity cost). Hosting/CI/bench infra ($2-5K/year). Conference travel + ICSE-SEIP submission ($5K/year). Legal review для dual-license (v1.0 prep, $10-20K). SOC 2 Type II audit ($50-100K v1.0 prerequisite). **Year 1-2 total: ≈$150-200K cash burn (mostly founder time-as-equity).** |
| 9 | **Потоки доходов** | **Year 1-2 (pre-v1.0):** $0 ARR (Apache 2.0 OSS). **Year 2-3 (v1.0+):** dual-license enterprise tier (audit-mode SIEM export, multi-tenant provenance dashboard) at $36K/year/seat для S4/S5 customers. **Year 3+:** managed hosting waitlist (founder forced decision per POS-MENTOR §5; not committed). **Target Year 3:** $180K-$1.4M ARR (POS-WEDGE §3 SOM). Никакого SaaS до v1.0 (positioning lock-in). |

---

## Sheet 7: Финмодель (3-Year P&L)

**Базовая (base case) проекция per POS-WEDGE §3 SOM:**

| Показатель | Год 1 (2026) | Год 2 (2027) | Год 3 (2028) | Примечания |
|---|---|---|---|---|
| Клиенты (кумулятивно) | 1 (Agency dogfood) → 3-5 (after first paying) | 50 active OSS installs, 3-5 paid contracts | 200 active installs, 15 paid contracts | OSS distribution растёт быстрее, paid contracts медленно |
| Выручка, млн ₽ | 0 → ~0.5 (1 contract × $5K test) | ~5 (3-5 contracts × ~$15K average) | **~16** (15 × $12K) base, до **~125** в bull (30 × $36K + 3 × $100K regulated) | Conversion @ 90₽/$ |
| CPU лицензии | — | — | — | Apache 2.0 OSS — no licensing revenue |
| GPU лицензии | — | — | — | Same — embedder через локальный Ollama bundled |
| ФОТ, млн ₽ | ~13 (1 FTE × 250K₽/мес × 12 + taxes/overhead 30%) | ~22 (1.5 FTE growth) | ~36 (2.5 FTE: founder + 1 senior eng + 0.5 support) | Founder time at market opportunity cost |
| Прочие операц. затраты, млн ₽ | ~1 (hosting, CI, conference travel) | ~2 (+ legal review для dual-license prep) | ~6 (+ SOC 2 audit ~$80K = ~7M₽) | SOC 2 — v1.0 prerequisite |
| Комиссии партнёрам, млн ₽ | — | — | TBD (если AWS adapter ship'нется + revenue share — pending 2026-05-30 verdict) | Conditional |
| Итого расходы, млн ₽ | ~14 | ~24 | ~42 | |
| EBITDA, млн ₽ | -14 (full burn) | -19 | **-26 base / +83 bull** | Pre-Series A profitable только в bull case |
| EBITDA margin, % | n/a (no revenue) | -380% | -163% base / +66% bull | Lifestyle business profitable, venture-scale gated на S4/S5 conversion |

**Honest framing (per POS-VC §6 + POS-MENTOR §3):**

- **Year 1-2 (2026-2027):** Lifestyle/reputation phase — founder pays cost as equity, Agency dogfood + ICSE-SEIP + outreach build credibility, no revenue expectation.
- **Year 3 (2028) base case:** $16M₽ ARR (~$180K USD) — sustainable lifestyle business with 2.5 FTE, no venture-scale return profile.
- **Year 3 (2028) bull case:** $125M₽ ARR (~$1.4M USD) requires 2-3 S4/S5 (regulated AI) customers signed by 2026-11 — gated на Mom Test interviews + 1-2 design partner pilots success.
- **Acquisition path (POS-VC §4):** Most likely $10-25M exit к Supabase / Neon / EDB к 2028-2029 conditional на v1.0 shipped + ≥3 external adopters + ICSE-SEIP acceptance. This is the honest base case, not consolation prize.

**TBD ячейки (требуют customer signal):**

- Year 2-3 actual revenue: TBD — pending Mom Test interviews verdict 2026-06-15 + первый paying S2 customer signed.
- Year 3 enterprise count: TBD — pending S4 design partner pilots результат к 2026-08-15 (POS-DATA §3 Gate F2 falsification check).
- AWS adapter revenue share: TBD — pending 3-day research spike verdict 2026-05-30.

---

*Filled by TL Karpov 2026-05-19 inline после 3-го no-op эскалейта Stage C #6398 (продакт-овнер агент закрылся в 1 turn $0.01 ignoring task description). Source: SYNTHESIS_VC_PGMNEMO_2026-05-17.md RATIFIED + 5 POS-* documents в /external-repos/pgmnemo/spec/competitive/. **Все 7 листов filled from locked verdicts**, никаких выдуманных чисел — где данных нет (Year 1 actual customer count), стоит TBD с явным trigger condition. Перенос в Google Sheets вручную фаундером.*
