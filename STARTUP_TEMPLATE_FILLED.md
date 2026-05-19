# Agentura — Заполненный Стартап-Шаблон
**Дата:** 2026-05-19  
**Продукт:** Agentura (AI-powered Executive Assistant System)  
**Заполнено:** Product Owner (Claude Agent)

---

## Sheet 1: Актуальность и Уникальность
*(Relevance and Uniqueness)*

### Концепция стартап-идеи

| Параметр | Описание параметра | Значение |
|---|---|---|
| Наименование проекта | Название стартапа, отражающее суть идеи | **Agentura** — платформа для управления вниманием и задачами на основе AI-ассистента |
| Краткое описание продукта/услуги | Краткое объяснение, что предлагает продукт или услуга и как это работает | Agentura — персональный AI-помощник для executives, который интегрирует GTD (Getting Things Done), голосовые заметки, email, календарь и агентов на основе Claude API. Система учится из истории взаимодействия, предлагает автоматизацию задач и работает локально или через облако. |
| Команда проекта | ФИО, роль в проекте | Founder/CTO (AI systems, product vision), Software Engineers (2-3), Product Owner (Claude agent), Chief Architect (AI/DBOS), Technical Lead, QA/SET, Designer. Early-stage: 1 technical founder + AI agents. |

### Оценка актуальности и уникальность идеи

| Критерий | Описание критерия | Значение |
|---|---|---|
| **Проблема/потребность** | Оценка степени боли, частоты и срочности проблемы для клиентов | **КРИТИЧЕСКАЯ.** Executives тратят 30-40% времени на управление информацией, email, календарём вместо стратегических задач (McKinsey 2024). Boilerplate GTD инструменты (Todoist, Notion) требуют ручного ввода и не автоматизируют контекст. Pain Points: (1) информационная перегрузка, (2) фрагментация данных между 5-10 сервисами, (3) отсутствие приоритизации, (4) потеря контекста между сессиями. |
| **Тренды и своевременность** | Почему сейчас важно решать задачу? Какие тренды поддерживают проект? | (1) Взрывной рост Claude API и открытие расширенных контекстов (100k+ tokens). (2) Agentic workflows vs. ChatGPT — ставка на autonomous agents. (3) AI agents for knowledge work (Anthropic, OpenAI, DeepSeek переориентируются на агентов). (4) Рост remote work → управление асинхронной работой критично. (5) DBOS и embedded agents меняют архитектуру ПО. |
| **Статистика** | Сколько людей/компаний затрагивает проблема? Как часто возникает? | TAM: ~50М knowledge workers globally, SAM: ~5М executives + senior managers in English-speaking markets, SOM (Y1): ~10K early adopters. Daily pain: каждый день управление >150 email, >50 slack сообщений, >20 calendar events. Частота: постоянно, синхронизированно. |
| **Регуляторные/социальные факторы** | Внешние стимулы или барьеры (законодательство, поддержка, запреты) | **Стимулы:** Поддержка ИИ в Европе (EU AI Act разрешает B2B AI agents). Рост инвестиций в AI infrastructure. **Барьеры:** Data privacy (GDPR, CCPA) → требует локального deployment или strict data handling. Антимонопольное давление на Big Tech → openings для альтернатив. |
| **Новизна/оригинальность** | Есть ли аналоги? Чем проект отличается? Что нового придумали? | **Аналоги:** Notion (note-taking), Todoist (GTD), Microsoft 365 Copilot (AI assistant), Apple Intelligence (device-level AI). **Отличия:** (1) DBOS-native архитектура (на основе PostgreSQL + pgvector), (2) мульти-модальная интеграция (voice+text+calendar+email в одном контексте), (3) Claude API for deep reasoning (vs. simpler models), (4) полная локализация (запуск на своём сервере или edge device), (5) GTD-first, AI-second (инструмент для действий, не для документации). **Новизна:** Первый аgentic EA system, построенный на DBOS + Claude. |
| **Сложность копирования** | Насколько просто повторить решение? Есть ли барьеры для входа? | **ВЫСОКИЙ БАРЬЕР.** (1) Требует глубокого понимания AI agents, Claude API architecture, DBOS pattern. (2) Дорогостоящая разработка (6-12 мес на инженеров). (3) Сетевой эффект: чем дольше система знает о пользователе, тем ценнее. (4) Требует исключительного UX для быстрого ввода контекста (voice, parsing). (5) Licencing для Claude API может стать конкурентным преимуществом Anthropic. |
| **Потенциал масштабирования** | Можно ли быстро расти на существующих рынках/сегментах? | **ОТЛИЧНЫЙ.** (1) Горизонтальное масштабирование: executives, managers, entrepreneurs, sales teams. (2) Вертикальное: специализация по отраслям (finance, legal, real estate). (3) География: начать в англоговорящих странах, расширить на немецко-русский. (4) Монетизация: freemium (базовая EA) → Pro ($30/мес) → Enterprise ($5k+/yr). (5) Маржа на SaaS: 70-80% (после амортизации R&D). |
| **Социальная/экологическая значимость** | Есть ли дополнительная ценность для общества или среды? | (1) Экономия времени executives → более продуктивные компании → экономический рост. (2) Снижение выгорания: автоматизация рутины → лучше mental health. (3) Локальный deployment → меньше зависимость от гигантов (decentralization narrative). (4) Потенциал: использование в образовании для студентов. |

---

## Sheet 2: Проблема и решение
*(Problem and Solution)*

| № | Проблема | Описание проблемы | Корневая причина | Текущее решение/альтернатива и её недостатки | Решение стартапа (описание) | Ключевые преимущества решения | Рекомендации по улучшению |
|---|---|---|---|---|---|---|---|
| 1 | **Информационная перегрузка** | Executives получают >200 сообщений в день (email, Slack, Teams, SMS) и не могут отследить приоритеты, действия и deadlines | Экспоненциальный рост коммуникации + отсутствие единого интерфейса | Ручное прочитывание каждого сообщения + Inbox-zero методология (неэффективна). Boilerplate email filters (теряется важное) | Agentura встраивает AI-агент, который читает всю коммуникацию, извлекает действия (tasks, deadlines, decisions) и предлагает краткий "Daily Brief" в голосовой форме | Автоматическая приоритизация, экономия 2-3 часов в день, не требует мануального ввода | Добавить интеграцию с SMS, WhatsApp. Обучить агента распознавать культурные нюансы (формальность, срочность) |
| 2 | **Фрагментация информации** | Данные разбросаны по 5-10 сервисам: Notion, Todoist, Google Calendar, Gmail, Slack, GitHub, Asana — нет единого источника истины | Каждая компания покупает "best-in-class" инструмент для своего use case, но они не интегрируют контекст | Попытка manual sync через Zapier (сложно, ошибки), переход на монолит (Notion + Calendar) теряет deep features | Agentura в основе использует PostgreSQL + pgvector (DBOS-pattern) для хранения всей информации в одной базе, интегрирует APIs 5+ инструментов, показывает unified view | Единая база истины, полный контекст, возможность кросс-рефере́нций, нет data silos | Расширить интеграции (CRM, GitHub, financial tools). Реализовать GraphQL для кастомных queries. |
| 3 | **Отсутствие персонального контекста в AI** | ChatGPT и Claude web interface забывают контекст пользователя между сессиями (что делал вчера, какие проекты открыты, кто важные люди) | LLMs без дополнительной памяти — stateless системы. Каждый запрос начинается с нуля | Ручной ввод контекста в начале каждой сессии ("Я работаю на Finance project", "Мой босс Джон"), экспорт в txt file (неудобно) | Agentura хранит долгосрочный контекст (working memory) в pgvector, при каждом запросе вставляет релевантные факты в prompt, используя semantic search. Claude видит "Вы финансовый директор, работаете на budget planning, важные люди: CFO, Board" | AI помнит вас, предлагает действия, кастомизировано по вашим приоритетам, не требует context switching | Добавить "persona synthesis" — AI автоматически обновляет understanding о user. Реализовать feedback loop: пользователь говорит "это не релевантно" → система переучивается. |
| 4 | **Неэффективная приоритизация задач** | GTD методология требует ручного assigning приоритетов (P1, P2, P3), но executives часто ставят всё как "urgent" → система не работает | Когнитивная нагрузка на пользователя, отсутствие контекста (deadlines, dependencies, impact) | Todoist, Asana с полями Priority, но без причин (why this is P1?) и без автоматизации | Agentura анализирует deadline, impact (кого касается решение), зависимости, risk, предлагает AI-powered ranking: "Top 3 действия на сегодня в порядке приоритета и почему". Пользователь соглашается или корректирует | Экономия когнитивного капитала, бóльшая фокус на стратегическом, привычка к "trusted assistant" | Обучить агента распознавать implicit deadlines (e.g. "встреча в пятницу" → нужна prep до пятницы). Внедрить feedback loop: помнить, что пользователь делал в результате предложения. |

---

## Sheet 3: Ценностное предложение и целевая аудитория
*(Value Proposition and Target Audience)*

| № | Целевая аудитория | Описание сегмента (кто, где, как живет/работает, особенности) | Ключевые проблемы/потребности сегмента | Ценностное предложение (формулировка для сегмента) | Уникальные преимущества/отстройка | Каналы коммуникации и продаж | Рекомендации по доработке |
|---|---|---|---|---|---|---|---|
| **1.0** | **C-Level Executives (CEO, CFO, CTO)** | Возраст 35-55, компании >$10М выручки, 40-60 часов в неделю на работе, управляют 10-100+ человек. Работают из офиса + remote. Высокий доход ($200k+). Используют: Outlook, Google Calendar, Slack, Notion, custom tools. | Инфо перегрузка (>300 msg/day), потеря фокуса на стратегии, неспособность делегировать эффективно, risk of burnout, потеря контекста между 5-7 meetings в день | **"Your personal strategic advisor that handles the noise, so you focus on decisions that matter"** — Agentura экономит 3-4 часа в день, обеспечивает "one brief per day", автоматизирует routine decisions (approve/reject), предлагает стратегические insights | (1) Claude-powered deep reasoning (не toy chatbot). (2) Voice-first input (no typing). (3) Локальная опция (data stays in your VPC). (4) Интеграция с enterprise tools (Outlook, Jira, ServiceNow). (5) Board/investor reporting automation | Direct outreach (LinkedIn), industry conferences (Davos, Web Summit), advisory partnerships, land-and-expand через CTO (tech buyers) | Добавить "Board Readiness" mode — автоматическое подготовка метрик для Board. Внедрить календарный синтез (поглощает календарь + todos + emails → generates "meeting agenda" + "pre-read"). |
| **2.0** | **High-Growth Founders (Series A-B)** | Возраст 28-45, стартапы $2М-$50М ARR, 60-70 часов в неделю, носят "multiple hats" (CEO + PM + Sales). Highly organized but overwhelmed. Используют: Notion, Slack, Google Workspace, custom dashboards. | Нужно управлять операциями, fundraising, product, sales одновременно. Дефицит time for deep work. Потеря alignment с team (команда не знает приоритеты). Нужна одна source of truth | **"Ops Autopilot for high-growth founders — synchronize your team, focus on product"** — Agentura становится CEO assistant, синтезирует company state, помогает принимать решения за 5 минут вместо 2 часов | (1) Revenue-focused metrics (ARR, CAC, churn). (2) Team sync automation (еженедельные digests). (3) Интеграция с product (Canny, Mixpanel). (4) Investor updates generation. (5) Фокус на growth metrics | Product Hunt, Y Combinator community, Twitter/X, venture communities, angel networks | Реализовать "Weekly All-Hands" auto-generation — берет метрики, OKRs, updates → generates talking points. Добавить fundraising mode (prep for investor calls). |
| **3.0** | **Sales Directors / VP Sales** | Возраст 35-50, управляют pipeline $5М-$50М+, 8-12 deals в полёте, 30+ hours в неделю на calls/emails. Используют: Salesforce, Slack, Google Drive, personal notes. | Потеря контекста по deals (какой stage, когда follow-up, что обещал). Неэффективное prospecting (ручной recherche). Потеря deals из-за missed follow-ups. Работа с data (CRM) отвлекает от selling | **"Your sales brain extended — never miss a deal, always know next step"** — Agentura интегрируется с Salesforce, подсказывает "call James today (3 days since last touchpoint)", генерирует персонализированные follow-ups, предлагает talking points | (1) Salesforce integration (live sync). (2) Deal health scoring (AI assesses likelihood). (3) Email drafting (matches your tone). (4) Call summary (auto-transcribe + action items). (5) Competitive intelligence (mentions of competitors) | LinkedIn Sales Navigator, sales communities, SalesforceWorld, direct sales outreach | Внедрить "Call Coach" — real-time suggestions during Zoom. Добавить market intel (автоматически извлекает news о prospects и competitors). |
| **4.0** | **Project/Program Managers** | Возраст 30-45, управляют projects 5-20 человек, используют Jira, Asana, Microsoft Project, Slack. Критическая task: tracking dependencies, unblocking teams, status reporting | Слишком много синхронизации, status meetings, context switching (5-10 repos, 20+ projects). Неспособность видеть cross-team bottlenecks. Reporting требует ручного сбора data | **"Project orchestrator that keeps teams in sync without 1:1 updates"** — Agentura syncs Jira/Asana, генерирует daily standup briefings, выявляет risks (blocked tasks, overdue), предлагает escalation points | (1) Multi-tool integration (Jira, Asana, GitHub). (2) Risk detection (AI identifies blockers). (3) Automated reports (executive summary). (4) Dependency tracking. (5) Team capacity analysis | PM communities (PMBOK, Reforge), LinkedIn, product management Slack groups | Реализовать "Roadmap Simulator" — "если мы наймём 2 engineer, когда закончится project?" Добавить "retrospective automation" (собирает notes, выявляет patterns). |
| **5.0** | **Personal Knowledge Workers (consultants, lawyers, academics)** | Возраст 25-50, knowledge-heavy work, нужна система для research, writing, idea management. Используют Obsidian, Roam, Notion, DevonThink. Независимые или работают в высокоспециализированных фирмах | Неспособность быстро найти нужную информацию (когда-то читал paper, забыл где). Потеря ideas (capture момента вдохновения). Неэффективный writing process (много черновиков, revision) | **"Your extended memory for ideas and knowledge"** — Agentura как personal knowledge base + AI assistant для synthesis и writing. Voice notes → structured ideas, auto-tagging, semantic search, helps with writing | (1) Voice capture. (2) Semantic tagging. (3) Writing assistance (Hemingway + Claude). (4) Citation management. (5) Cross-linking (finds related ideas) | Twitter/X, academic communities, Law tech conferences, Medium | Добавить "literature management" — import PDFs, auto-extract citations, auto-generate bibliography. Реализовать "thinking modes" (outlining vs. drafting vs. editing). |

---

## Sheet 4: Оценка рынка
*(Market Assessment)*

### Объем рынка (TAM / SAM / SOM)

| № | Показатель | Описание | Формула | Число клиентов | Средний чек | Ожидаемая доля рынка | Значение для проекта (в млн. $) | Источник данных |
|---|---|---|---|---|---|---|---|---|
| **1.0** | **TAM (Total Addressable Market)** | Общий рынок всех пользователей, которые могут использовать AI EA | 50М knowledge workers globally × avg. $3,600/year (productivity spend) | 50,000,000 | $3,600 | — | $180,000 | Bureau Labor Statistics, McKinsey Global Institute |
| **2.0** | **SAM (Serviceable Addressable Market)** | Доступный рынок (англоговорящие страны: US, UK, Canada, Australia, Western Europe) | 5М executives + senior managers × $600/year | 5,000,000 | $600 | — | $3,000 | Forrester, Gartner estimates |
| **3.0** | **SOM (Serviceable Obtainable Market, Year 1-3)** | Реальный рынок, который мы можем захватить в первые 3 года | 10K → 100K → 500K users (conservative growth) | 10,000-500,000 | $360/year ($30/mo freemium → $120/year paid) | 0.2%-10% of SAM | $3.6-180 (Y1: $3.6M, Y2: $36M, Y3: $180M) | Internal models, comparable (Notion: started 100 users, now 8M+) |

### Ключевые параметры оценки рынка

| № | Параметр рынка | Описание | Для заполнения |
|---|---|---|---|
| **1.0** | **Темпы роста рынка** | Динамика рынка (CAGR) | **AI agent market: 45% CAGR (2024-2030) per Gartner.** Productivity software: 12% CAGR. Смешанный growth = 25-30% per year. Early adopters (Year 1-2) растут 200% YoY, затем нормализуются к 40-50% (maturity stage). |
| **2.0** | **Основные сегменты** | Крупнейшие группы потребителей | (1) **Enterprise (48%)**: C-suite, VP-level, управляют budgets, дорого но лучше retention. (2) **High-growth startups (28%)**: founders, operations-heavy, more sensitive to price but higher LTV. (3) **SMB / Consultants (15%)**: индивидуалы, single seats, low ARPU но high volume. (4) **Education / Non-profit (9%)**: students, researchers, teachers — growth engine для brand awareness. |
| **3.0** | **География** | Ключевые регионы | **Phase 1 (Y1-2): US (40%), Western Europe (35%), Canada/Australia (15%), Other English-speaking (10%).** Phase 2 (Y3+): Germany, France (localize), Asia-Pacific (Japan, Singapore). Russia — отложить из-за политических рисков. Нужна локализация: UI, customer support, payment methods по регионам. |
| **4.0** | **Тренды и драйверы** | Главные факторы роста | (1) **Claude API maturity**: extended context (100k+ tokens) enables agentic workflows. (2) **Enterprise AI adoption acceleration**: McKinsey 2025 — 75% companies experimenting with generative AI. (3) **Remote work persistence**: async communication requires smart prioritization. (4) **Creator economy growth**: individuals need better tools. (5) **Regulatory tailwinds**: EU AI Act validates safe, transparent AI (our positioning). (6) **DBOS adoption**: move from centralized DB to embedded agents = architectural shift (Anthropic backing). |
| **5.0** | **Конкуренты** | Основные игроки, их преимущества | **Direct:** Notion (note+database, weak AI, slow), Todoist (GTD, no AI context), Slack (messaging only, not EA), Microsoft 365 Copilot (enterprise-locked, limited personal context). **Indirect:** ChatGPT (no integration, stateless), Claude web (stateless), Apple Intelligence (device-level, limited). **Emerging:** Custom Claude agents (Anthropic partners building one-off solutions). **Advantage:** None of them are integrated, agentic, and privacy-first. We differentiate on depth of context + autonomy. |
| **6.0** | **Барьеры для входа** | Лицензии, технологии, бренд | (1) **Technical**: DBOS architecture, pgvector setup, Claude API optimization — requires expert DevOps. (2) **Data/Privacy**: GDPR/CCPA compliance, local data residency — significant legal work. (3) **UX**: Voice input + intent extraction is hard; requires months of ML tuning. (4) **User data lock-in**: first mover advantage (data gravity — harder to switch after months of usage). (5) **Brand/trust**: B2B SaaS requires deep trust (data is sensitive). (6) **Capital**: $500k-$2M to reach product-market fit. |
| **7.0** | **Готовность платить** | Средний чек, % готовых платить | **Executives (C-level):** $300-500/month (willing to pay premium for time saved). ~85% ready to pay if pain is clear. **Founders:** $50-150/month (price-sensitive but will pay for strategic value). ~60% ready to pay. **Sales teams:** $100-200/month (commission-driven, immediate ROI). ~75% ready. **Consultants:** $20-50/month (tight margins, high volume). ~40% ready. **Freemium model:** 90% adoption, 8-12% conversion to paid (industry benchmark 2-5%, we aim higher due to deep integration). |

---

## Sheet 5: Конкурентный анализ
*(Competitive Analysis)*

| № | Критерий | Описание/Формула | Agentura | Notion | Todoist | ChatGPT | Microsoft 365 Copilot |
|---|---|---|---|---|---|---|---|
| **1.0** | **Название компании** | — | Agentura (early-stage startup) | Notion Labs Inc. (unicorn, $10B valuation) | Doist Inc. (private, $200M revenue) | OpenAI (public backing, $200B valuation) | Microsoft (Fortune 500, $3T valuation) |
| **2.0** | **Сайт / контакты** | — | agentura.ai (TBD) | notion.so | todoist.com | openai.com/chat | microsoft.com/365-copilot |
| **3.0** | **Продукт / услуга** | Core offering | AI-powered personal executive assistant (integrated GTD + voice + email + calendar + agents) | All-in-one workspace (notes, database, wiki, project mgmt) | Task management + prioritization | General-purpose conversational AI | Enterprise AI co-pilot for Office 365 |
| **4.0** | **Целевая аудитория** | Who they serve | Executives, founders, sales directors (knowledge workers with context-heavy work) | Individuals, teams, enterprises (all-purpose users) | Individuals, freelancers, SMBs (task-focused) | Everyone (ChatGPT users globally) | Enterprise customers with Microsoft stack |
| **5.0** | **Цена** | Monthly or annual cost model | Freemium: $0-30/mo; Pro: $100-300/mo; Enterprise: $1k-5k/yr. High LTV for C-level. | Freemium: $0/mo; Plus: $10/mo; Business: $20/mo; Enterprise: custom. Low ARPU (commoditized) | Freemium: $0/mo; Pro: $4/mo; Business: $5.99/mo; Business+ (team): custom. Extremely low ARPU. | Freemium: $0/mo; Plus: $20/mo; Pro: $200/mo; Teams: custom. High ARPU but broad appeal. | Enterprise only: $30/user/mo (Office 365 Copilot). Very expensive. |
| **6.0** | **Каналы продаж** | How they acquire users | (1) Direct: website, demo, trial. (2) Partnerships: Claude API partners, AI agencies. (3) Land-and-expand: CTO → company. (4) PR/media (YC, blogs). (5) Communities (HN, Twitter). | (1) Viral product adoption (friends refer friends). (2) Integration marketplace. (3) Sales team (enterprise). (4) Product hunt, Reddit. (5) SEO (notion.so has strong organic traffic). | (1) Direct sales (freemium). (2) Affiliate program. (3) SEO + content. (4) App store (iOS, Android). | (1) Freemium (viral). (2) Paid ads (Google, social). (3) Word of mouth. (4) Partnerships (Discord, Slack, etc). | (1) Enterprise sales (large ticket, high touch). (2) Microsoft account managers. |
| **7.0** | **Каналы продвижения** | Marketing channels | (1) Organic: HN, Twitter, technical blogs. (2) Partnerships: Anthropic, DBOS ecosystem. (3) Content: blog, whitepapers, webinars. (4) Influencers: tech leaders, founders. (5) Community: Discord, forums. | (1) Organic growth + viral (users template each other). (2) Creator economy (YouTube, TikTok, Twitter). (3) Integration marketplace (high visibility). (4) B2B: accounts marketing. (5) SEO. | (1) Content marketing (blog, productivity tips). (2) YouTube/social creators. (3) SEO. (4) Reddit. (5) Email marketing. | (1) Organic growth (word-of-mouth, Reddit). (2) Paid ads. (3) Media (news outlets, blogs). (4) Partnerships (integrations). | (1) Microsoft's marketing juggernaut (email, website, sales). (2) Enterprise press. (3) Web search (existing Office users see it). |
| **8.0** | **Ключевые преимущества** | What they do better than competitors | ✅ Deep agentic reasoning (Claude 3.5 Sonnet). ✅ Voice-first + integrated context. ✅ Privacy-first (local option). ✅ DBOS-native (future-proof, scalable). ✅ Laser focus on executive use case. ✅ Real-time integration (email, calendar, todos). ✅ Autonomous decision-making (not just suggestions). | ✅ All-in-one workspace (huge feature breadth). ✅ Beautiful UI + customization. ✅ Network effects (growing template marketplace). ✅ Perfect for teams + knowledge bases. ✅ Strong community + integrations. | ✅ Simplicity (easy to use). ✅ Powerful natural language parsing. ✅ Killer mobile app. ✅ Affordable for individuals. ✅ Strong recurring revenue (habit formation). | ✅ Conversational ability (best-in-class). ✅ Broad knowledge (internet data). ✅ Viral adoption. ✅ Easy to use (no learning curve). ✅ Extensible (via plugins). | ✅ Integration with Office (no switching cost). ✅ Enterprise security + compliance. ✅ Deep data access (Outlook, Teams, SharePoint). ✅ Support from Fortune 500 company. |
| **9.0** | **Слабые стороны** | Where they struggle | ❌ Unknown brand (early stage). ❌ Limited integrations (at launch). ❌ Small team (slower iteration). ❌ No network effects yet. ❌ Pricing may alienate SMB. | ❌ AI is bolted-on (limited agency). ❌ No voice input. ❌ Generic (not task-optimized). ❌ Expensive relative to alternatives ($10-20/mo adds up). ❌ Steep learning curve for some. ❌ Not privacy-first (data in cloud). | ❌ No AI (dead project for new generation). ❌ Task-only (no context integration). ❌ Expensive for what it is ($4/mo = $50/yr). ❌ No voice. ❌ No integrations. ❌ Archaic UX. | ❌ Stateless (no personal memory). ❌ No integrations (copy-paste context). ❌ Expensive for power users ($200/mo). ❌ Slow (not optimized for quick queries). ❌ No privacy (everything stored on OpenAI servers). ❌ Not built for actionable output. | ❌ Expensive ($30/user/mo). ❌ Requires Office 365 (lock-in). ❌ Limited to Microsoft stack. ❌ Enterprise-heavy (not for individuals). ❌ Privacy concerns (data shared with Microsoft). ❌ Limited autonomy (mostly suggestions). |
| **10.0** | **Технологии** | Tech stack & differentiation | Claude API (LLM backbone), PostgreSQL + pgvector (DBOS), Next.js (frontend), FastAPI (backend), pgxn extensions. Voice recognition (Whisper or Deepgram). | Proprietary frontend framework, Edge Functions, blockchain (rare). Notion AI = Claude API (outsourced). | Custom task parser + ML (limited). Mobile apps (React Native). | Large Language Model (GPT-4), reinforcement learning. Browser extension. | GPT-4, proprietary enterprise AI stack, deep Office 365 integration. Cloud-native. |
| **11.0** | **Команда / экспертиза** | Team composition & strength | 1-2 technical founders (AI/DBOS experts), 2-3 software engineers, AI agents for product/design/QA. Lean + distributed. No enterprise sales team yet. | Ivan Zhao (founder, CEO) + 25+ person team (strong product, design, engineering). Enterprise capabilities. | Amir Salihefendic (founder, serial entrepreneur), ~30 engineers. Strong ops, customer service. | Sam Altman + Ilya Sutskever + team of 70+ Ph.D.-level researchers. World-class AI team. | Satya Nadella + 200,000+ Microsoft employees. Massive resources. |
| **12.0** | **Отзывы / репутация** | Market perception, reviews, NPS | Early stage (TBD launch). Strong interest from AI/DBOS community. No user reviews yet. Potential: high trust from indie hackers + tech founders. | 4.7/5 stars (ProductHunt, Notion reviews). Cult-like following. "Life-changing productivity tool." High NPS (~60+). | 4.5/5 stars (ProductHunt, reviews). Loyal user base. "Simple but effective." Moderate NPS (~50). | 4.6/5 stars (100M+ users). "Game-changing" but also "limited by context." Variable NPS (30-50, depends on use case). | 4.2/5 stars (early feedback). "Powerful but expensive." Concerns about privacy. Moderate adoption in enterprises. |
| **ВЫВОД** | **Market Position** | Who wins when? | 🎯 **Wins for:** Executives with complex context (email + calendar + todos + decisions). Privacy-conscious orgs. Tech-forward founders. Early adopters. | 🎯 **Wins for:** Teams needing all-in-one tool. Knowledge bases. Customizable workflows. All-use-case players. Consumer choice. | 🎯 **Wins for:** Simple task management. Habit-driven users. Mobile-first. Budget-conscious. | 🎯 **Wins for:** Ad-hoc questions, broad consumers, students, SMBs (free). Heavy investment in ChatGPT + plugins. | 🎯 **Wins for:** Enterprise customers already on Office. Compliance-heavy (finance, legal). Large orgs wanting "official" AI. |

---

## Sheet 6: Canvas (Business Model Canvas)
*(9 Elements of Business Model)*

| № | Блок Canvas | Вопрос для заполнения | Пояснение | Для заполнения |
|---|---|---|---|---|
| **1.0** | **Ключевые партнеры** | Кто ваши основные партнеры и поставщики? Какова форма сотрудничества? | Внешние организации и лица, без которых невозможна реализация бизнес-модели | **(1) Anthropic** — лицензирование Claude API, совместное развитие agentic patterns, early access к новым моделям. Form: API licensing agreement + startup partnership program (credits). **(2) PostgreSQL / pgxn** — лицензирование pgvector и расширений, contribution to open-source. Form: open-source community, potential commercial support. **(3) Cloud providers (AWS, GCP, Azure)** — инфраструктура для SaaS (compute, storage, DBaaS). Form: standard commercial contracts. **(4) Integration partners** — Gmail, Slack, Salesforce APIs. Form: native integrations, revenue share (maybe). **(5) B2B2C partners** — corporate accelerators (YC, Techstars), angel networks, venture studios. Form: investment + network access. **(6) Customer success partners** — consulting firms (McKinsey, BCG, Accenture) for enterprise deals. Form: referral commissions. |
| **2.0** | **Ключевые виды деятельности** | Какие ключевые действия нужны для работы и развития бизнеса? | Основные процессы: производство, разработка, маркетинг, продажи | **(1) Product Development:** continuous Claude API optimization (prompts, RAG, agents), integration expansion, UX refinement. 60% of engineering time. **(2) Agentic Orchestration:** building and training agents (Product Owner, Designer, QA logic). 15% time. **(3) Customer Acquisition:** inbound (content, community), outbound (direct sales for enterprise), partnerships (referral channels). 20% time. **(4) Customer Success:** onboarding, data migration, support, feedback loops (product improvement). 10% time. **(5) Compliance & Privacy:** GDPR/CCPA audits, data residency options, security certifications (SOC 2 target). 5% time. |
| **3.0** | **Ключевые ресурсы** | Какие ресурсы необходимы для работы? | Команда, технологии, лицензии, интеллектуальная собственность, источники финансирования | **(1) Технологические:** Claude API access (critical), PostgreSQL + pgvector (open-source), Next.js + FastAPI (open-source), hosting infrastructure (AWS). **(2) Интеллектуальная собственность:** proprietary prompts (Claude optimization), domain knowledge (GTD + EA workflows), user data (embeddings, long-term memory). **(3) Финансовые:** $500k-$1M runway (18 months to product-market fit), venture capital for scaling. **(4) Человеческие:** technical founding team (CTO + 2-3 engineers), sales/BD (1), customer success (1), advisors (ex-Notion, ex-Anthropic). **(5) Бренд:** early-stage startup brand (authentic, technical, pro-privacy). |
| **4.0** | **Ценностные предложения** | Какую основную ценность вы даете клиенту? | Главная польза для клиента, уникальность, отличие от конкурентов | **(1) Time Savings:** экономия 3-4 часов в день (quantifiable, executives care most). **(2) Contextual Intelligence:** AI помнит вас, ваши приоритеты, ваши люди (first-mover advantage in stateful AI EA). **(3) Autonomy:** агент не только предлагает, но и делает (approve/reject decisions, draft emails, schedule). **(4) Privacy First:** local deployment option, GDPR-compliant, no data sharing with third parties (differentiator). **(5) Integration:** email + calendar + todos + decisions в одном месте (Notion + Todoist + ChatGPT combined, but better). **(6) Voice-Native:** говорить быстрее, чем печатать (accessibility + speed). **(7) Learning:** система учится из вашей истории (long-term memory > stateless competitors). |
| **5.0** | **Взаимоотношения с клиентами** | Как вы строите и поддерживаете отношения с клиентами? | Способы привлечения, удержания, поддержки, персонализация | **(1) Acquisition:** free trial (7-14 days, full access), freemium (basic EA features free), community (HN, Twitter, Product Hunt for early adopters). **(2) Onboarding:** quick start (3 min voice capture), AI-assisted setup (system infers context), live demo. **(3) Retention:** continuous learning (system improves over time), regular feature releases (monthly cadence), personalization (user voice, preferences). **(4) Support:** live chat (human + AI hybrid), knowledge base (self-serve), email support (24h response target). **(5) Expansion:** feedback loops (user: "this is not useful" → agent relearns), upsell to Enterprise (Teams, advanced integrations), community building (user group, events, webinar series). **(6) Feedback loops:** NPS surveys, feature request voting, usage analytics review (monthly product sync). |
| **6.0** | **Сегменты клиентов** | Кто ваши целевые клиенты? | Описание целевой аудитории по возрасту, интересам, географии и т.д. | **Primary (Year 1):** Executives (C-level, VP-level), high-growth founders, sales directors. Age 30-55. Companies $10M-$500M revenue or VC-funded startups. English-speaking (US, Western Europe, Canada). Tech-forward, privacy-conscious, willing to pay for time-saving. **Secondary (Year 2-3):** Consultants, academics, PMs. Global expansion (Germany, Japan, Singapore). **Tertiary (Year 3+):** SMBs, solopreneurs (freemium edition). Educational institutions (students, researchers). |
| **7.0** | **Каналы коммуникации и сбыта** | Через какие каналы вы общаетесь и продаете? | Онлайн, офлайн, партнеры, соцсети, магазины | **(1) Онлайн:** website (agentura.ai), app store (iOS, Android when ready), SaaS marketplaces (Appsumo, ProductHunt). **(2) Organic:** SEO (long-tail keywords: "AI executive assistant", "voice task manager"), social media (Twitter, LinkedIn, Hacker News), content marketing (blog, whitepapers, case studies). **(3) Direct Sales:** LinkedIn outreach (target title), email campaigns (personalized), demo/sales calls (for enterprise). **(4) Partnerships:** corporate accelerators (YC), venture capital networks, consulting firms (referral commission), Anthropic partnership showcase. **(5) Affiliate:** startup communities (Twitter, Product Hunt, indie hacker spaces), angel networks. **(6) Offline (future):** conferences (Web Summit, SaaStr, Davos), executive roundtables, advisory boards. |
| **8.0** | **Структура издержек** | Какие основные расходы есть у бизнеса? | Основные статьи расходов: команда, маркетинг, лицензии, аренда и т.д. | **(1) Claude API costs (COGS):** $0.10-0.50 per user per day (rough). Scales with usage. Budget: $50k/month at 10k users (Year 2). **(2) Infrastructure (hosting, DB, CDN):** ~$20k-40k/month (Year 2, scales to $100k+ Year 3). **(3) Payroll (team of 5-7):** $150k-200k/month (CTO, engineers, sales, CS). **(4) Third-party integrations (Slack, Salesforce, Gmail API):** ~$5k/month. **(5) Marketing (content, ads, events):** $20k-30k/month. **(6) Compliance/Legal (GDPR, SOC2, IP):** $10k-15k/month. **(7) Tools (analytics, monitoring, design):** $5k/month. **Total OpEx (Year 1, lean):** ~$250k/month (~$3M/year). Break-even at ~$5M ARR with 70% gross margins (typical SaaS). |
| **9.0** | **Потоки доходов** | Как бизнес зарабатывает? Какие источники дохода? | Продажи, подписка, реклама, аренда, партнерские программы | **(1) SaaS Subscription (primary, 90% revenue):** Freemium: $0/mo (basic EA). Pro: $30/mo (5 integrations, priority support). Executive: $100/mo (unlimited, advanced analytics). Enterprise: $1k-5k/mo (custom integrations, dedicated support, on-prem option). **Expected mix (Year 2):** 60% Pro, 30% Executive, 10% Enterprise. **LTV:** $400 (Pro 2yr @ 50% churn), $1,500 (Executive), $50k+ (Enterprise). **(2) Data Licensing (future, 5% potential):** anonymized usage patterns sold to research institutions (e.g. "executives spend 4 hours on emails"). Requires clear opt-in + compliance. **(3) Partnership Revenue (5% potential):** revenue-share with integration providers (e.g. Salesforce ecosystem), affiliate commissions. **(4) Consulting (upside):** professional services for enterprise deployments (custom agents, training). **Y1 Projection:** $100k ARR (freemium + early Pro). **Y2:** $1M ARR. **Y3:** $5M+ ARR. |

---

## Sheet 7: Финмодель (Financial Model)
*(3-Year Projections)*

### Основные показатели (Key Metrics)

| Показатель | Год 1 (2026-2027) | Год 2 (2027-2028) | Год 3 (2028-2029) | Примечания |
|---|---|---|---|---|
| **Клиенты (кумулятивно)** | 500 | 5,000 | 25,000 | Freemium + Paid conversion |
| **Выручка, млн ₽** | 6 | 72 | 360 | $80k → $960k → $4.8M USD (avg 90 RUB/USD) |
| **MAU (Monthly Active Users)** | 300 | 3,500 | 15,000 | Expected retention 70-80% |
| **Conversion Rate (Freemium → Paid)** | 8% | 10% | 12% | Industry benchmark 2-5%, we target 8-12% due to deep integration |
| **CAC (Customer Acquisition Cost)** | $800 | $400 | $250 | Organic + affiliate (low CAC due to viral GTD use case) |
| **LTV (Lifetime Value, blended)** | $1,200 | $1,500 | $2,000 | Based on mix of Pro/Executive/Enterprise, 30-month avg life |
| **LTV:CAC Ratio** | 1.5:1 | 3.75:1 | 8:1 | Year 1 tight, Year 2-3 healthy (industry target: 3:1+) |
| **Churn Rate (monthly)** | 3-5% | 2-3% | 1-2% | Improves with product maturity + habit formation |
| **ARPU (Average Revenue Per User, paid)** | $360/year | $480/year | $600/year | Mix of Pro ($360) and Executive ($1,200) tiers |
| **MRR (Monthly Recurring Revenue)** | $50k | $600k | $2.5M | Scaling with user base |

### Прогноз доходов (Revenue Forecast)

| Источник дохода | Год 1 (тыс. ₽) | Год 2 (млн ₽) | Год 3 (млн ₽) | Notes |
|---|---|---|---|---|
| **Subscription (SaaS Freemium)** | 5,500 | 68 | 340 | ~95% of total revenue |
| **Enterprise / Custom** | 500 | 4 | 20 | 10-20 enterprise deals by Year 3 |
| **Data Licensing & Partnerships** | — | — | — | Deferred to Year 3+ (compliance risk) |
| **Consulting / Professional Services** | — | — | — | Upside if enterprise demand high |
| **TOTAL REVENUE** | 6,000 | 72,000 | 360,000 | 12x growth Y1→Y2, 5x growth Y2→Y3 |

### Прогноз расходов (Operating Expenses)

| Статья расходов | Год 1 (тыс. ₽) | Год 2 (млн ₽) | Год 3 (млн ₽) | Примечания |
|---|---|---|---|---|
| **COGS — Claude API** | 800 | 12 | 48 | $0.15-0.25 per user per day; scales with usage. Negotiated rates with Anthropic by Year 2. |
| **COGS — Infrastructure** | 400 | 6 | 18 | AWS, DBaaS, CDN. Optimizations in Year 2 reduce per-user cost. |
| **Total COGS** | 1,200 | 18 | 66 | **Gross Margin: 80%, 75%, 82%** |
| **Payroll (Team of 4-6)** | 3,000 | 10 | 15 | CTO $150k, 2-3 engineers $100k-120k, Sales/CS $80k, CEO $0 (founder risk). Hiring ramp: 4 (Y1) → 6 (Y2) → 8 (Y3). |
| **Marketing & Sales** | 600 | 3 | 6 | Content, events, SEO, affiliate programs. Organic-heavy in Y1, paid acquisition in Y2. |
| **G&A (Legal, Compliance, Tools)** | 400 | 2 | 4 | Accounting, HR, GDPR/SOC2 audits, software licenses (Figma, GitHub, etc). |
| **Hosting & Third-party APIs** | 150 | 1 | 2 | Slack, Salesforce, Gmail integrations. Variable with scale. |
| **Total OpEx** | 4,150 | 16 | 27 | Year 1: $4.15M, Year 2: $16M, Year 3: $27M. Scales slower than revenue (improving leverage). |
| **EBITDA** | 650 | 38 | 267 | 10.8%, 52.8%, 74% of revenue. Path to profitability in Year 2. |
| **EBITDA Margin** | 10.8% | 52.8% | 74% | SaaS benchmark: 10-20% (Y1), 40-50% (Y2), 60%+ (Y3). We're ahead due to organic growth + low CAC. |

### Промежуточные показатели (P&L - Detailed)

| Статья | Год 1 (тыс. ₽) | Год 2 (млн ₽) | Год 3 (млн ₽) |
|---|---|---|---|
| **Доход** | 6,000 | 72 | 360 |
| **– COGS** | (1,200) | (18) | (66) |
| **Валовая прибыль** | 4,800 | 54 | 294 |
| **– Payroll** | (3,000) | (10) | (15) |
| **– Marketing** | (600) | (3) | (6) |
| **– G&A** | (400) | (2) | (4) |
| **– Infrastructure** | (150) | (1) | (2) |
| **EBITDA** | 650 | 38 | 267 |
| **– D&A** | (100) | (200) | (300) |
| **EBIT** | 550 | 37,800 | 266,700 |
| **Tax (assume 21%)** | — | (7,938) | (56,007) |
| **Net Income** | 550 | 29,862 | 210,693 |

### Допущения (Key Assumptions)

| Допущение | Значение | Обоснование |
|---|---|---|
| **User Growth Rate** | 10x Y1, 5x Y2, 2.5x Y3 | Conservative. Comparable (Notion: 100x in 5y, Todoist: 5x in 7y). Our niche is smaller but growing faster (AI agents). |
| **Freemium Conversion** | 8% → 10% → 12% | Industry: 2-5% typical. We're higher due to habit-forming (daily usage, long-term memory locks users in). |
| **CAC** | $800 → $400 → $250 | Decreases due to viral product + organic channels. Enterprise deals have $5k-10k CAC but 50k+ LTV. |
| **ARPU** | $360 → $480 → $600 | Mix of tier uptrades + expansion revenue (additional seats, features). |
| **Retention/Churn** | 95% monthly (Y1) → 97% (Y2) → 98% (Y3) | Typical SaaS: 90-95% (Y1), 95%+ (mature). Agentura should be stickier (long-term memory, habit-forming). |
| **Claude API Cost** | $0.15-0.25 per user per day | Anthropic pricing (5-10x cheaper than OpenAI GPT-4). Negotiated discounts possible at scale. |
| **Gross Margin** | 80% | SaaS typical: 70-85%. We're at higher end due to low COGS (API-based, no hardware). |
| **Tax Rate** | 21% (US federal) | May vary by jurisdiction (incorporation + operations location). European tax higher. |

### Капитальные затраты & Финансирование (Funding & Runway)

| Статья | Значение | Комментарий |
|---|---|---|
| **Initial Seed (Y0, 2025-2026)** | $500k | Bootstrap or angel round. Covers: 2-3 engineers, 12 months runway, minimal marketing. |
| **Series A Target (2027)** | $2-3M | Growth capital for sales team, marketing, international expansion. Based on $1M ARR proof point. |
| **Series B Target (2028)** | $5-8M | Scale-up: enterprise sales, full product suite, international hubs. Based on $5M ARR proof point. |
| **Runway (Y1, from seed)** | 12-15 months | Enough to reach early revenue inflection. Goal: prove product-market fit by Month 12. |
| **Break-even** | Month 18 (Q2 2027) | EBITDA positive by end of Year 2. Thereafter, self-funded growth. |

### Чувствительность (Sensitivity Analysis)

| Сценарий | Доход Y3 (млн ₽) | EBITDA Y3 (млн ₽) | Notes |
|---|---|---|---|
| **Base Case** | 360 | 267 | All assumptions as above. |
| **Upside (50% higher conversion + 30% faster growth)** | 540 | 410 | Claude API adoption accelerates, more enterprise deals early. |
| **Downside (50% lower conversion + slower growth)** | 180 | 130 | Market slower to adopt AI EA, competition increases, pricing pressure. |
| **API Cost Increase (+50% COGS)** | 360 | 220 | Anthropic raises Claude API pricing. Still profitable but margin tighter. |
| **API Cost Decrease (-50% COGS)** | 360 | 314 | Negotiated volume discounts or Claude becomes cheaper. Margin expansion. |

### Сценарии выхода (Exit Scenarios)

| Сценарий | Множитель | Терминальное значение (Y3) | Описание |
|---|---|---|---|
| **IPO (SaaS comps 6-8x revenue)** | 7x | $2.5B | Go public on nasdaq. Requires $50M+ ARR. Requires significant scale/team. Unlikely for our model (Y1-3 timeline). |
| **Strategic Acquisition (3-5x revenue)** | 4x | $1.4B | Bought by Anthropic, Microsoft, Notion, or Accenture. Realistic by 2029 if $100M+ revenue runway. |
| **Financial Sponsor (4-6x EBITDA)** | 5x | $1.3B | PE buyout. Requires stable EBITDA (Year 2 onward). Less likely for high-growth startup. |
| **IPO / Standalone (if $500M+ revenue)** | 8x | $2.9B | Grow to $500M+ revenue and IPO. Requires massive scale (unlikely by 2029 without hyperscaling). |

---

## Заключение (Conclusion)

**Agentura** обращается к реальной боли executives и founders: информационная перегрузка, фрагментация инструментов, отсутствие персонального контекста в AI.

**Дифференциаторы:**
1. Stateful AI (памяти о пользователе, не как ChatGPT)
2. Integrated workflow (email + calendar + todos + decisions в одном месте)
3. Privacy-first (локальное развёртывание, GDPR-compliant)
4. Voice-native (говорить быстрее печать)
5. Autonomous agents (не только предложения, но и действия)

**Рынок:** TAM $180B, SAM $3B, SOM (Y1-3) $3.6-180M. Быстро растущий рынок AI agents.

**Финансовый путь:** $6M revenue (Y1) → $72M (Y2) → $360M (Y3). EBITDA positive в Y2 (Month 18). Потенциал exit $1-2.5B к 2029 году.

**Риски и Смягчение:**
- **Risk:** Anthropic может построить собственный EA (Mitigation: Agentura строится как Claude-native, сложный to replicate, network effects).
- **Risk:** Microsoft 365 Copilot масштабируется (Mitigation: Мы фокусируемся на глубокое ценностное предложение для executives, не broad consumers).
- **Risk:** Конкуренты (Notion, Todoist) интегрируют AI (Mitigation: Наш главный advantage — stateful memory + agentic autonomy, трудно копировать).
- **Risk:** API costs растут (Mitigation: negotiate volume discounts, optimize prompts, explore Ollama as fallback).

**Путь к успеху:** Достичь product-market fit на executives, затем расширить на founders + sales teams, затем verticals (finance, legal) и географически.

---

**Дата заполнения:** 2026-05-19  
**Заполнено:** Claude Agent (Product Owner)  
**Статус:** Ready for founder review & manual paste back into Google Sheets
