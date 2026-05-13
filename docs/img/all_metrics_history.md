# pgmnemo — all metrics × all versions

Tufte-style sparkline table. Each row is one (benchmark × scope × metric).

![all metrics history](all_metrics_history.svg)



## LoCoMo session-level  (DRAGON, paper-canonical headline)

| scope | metric | v0.2.1 | v0.3.0 | Δ first→latest |
|---|---|---|---|---|
| **OVERALL** | `recall@5` | 0.662 | 0.664 | ─0.17pp |
| **OVERALL** | `recall@10` | 0.795 | 0.799 | ─0.43pp |
| **OVERALL** | `recall@25` | 0.962 | 0.964 | ─0.18pp |
| **OVERALL** | `recall@50` | 0.999 | 1.000 | ─0.03pp |
| **OVERALL** | `mrr` | 0.548 | 0.557 | ▲0.89pp |
| **single_hop** | `recall@5` | 0.503 | 0.488 | ▼1.53pp |
| **single_hop** | `recall@10` | 0.681 | 0.673 | ▼0.79pp |
| **single_hop** | `recall@25` | 0.934 | 0.934 | ─0.09pp |
| **single_hop** | `recall@50` | 0.997 | 0.999 | ─0.18pp |
| **single_hop** | `mrr` | 0.595 | 0.586 | ▼0.94pp |
| **multi_hop** | `recall@5` | 0.682 | 0.670 | ▼1.19pp |
| **multi_hop** | `recall@10` | 0.834 | 0.827 | ▼0.78pp |
| **multi_hop** | `recall@25` | 0.984 | 0.989 | ─0.47pp |
| **multi_hop** | `recall@50` | 1.000 | 1.000 | ─0.00pp |
| **multi_hop** | `mrr` | 0.543 | 0.559 | ▲1.57pp |
| **temporal** | `recall@5` | 0.482 | 0.444 | ▼3.81pp |
| **temporal** | `recall@10` | 0.660 | 0.645 | ▼1.49pp |
| **temporal** | `recall@25` | 0.927 | 0.929 | ─0.27pp |
| **temporal** | `recall@50` | 1.000 | 1.000 | ─0.00pp |
| **temporal** | `mrr` | 0.401 | 0.384 | ▼1.71pp |
| **open_domain** | `recall@5` | 0.701 | 0.718 | ▲1.66pp |
| **open_domain** | `recall@10` | 0.819 | 0.838 | ▲1.96pp |
| **open_domain** | `recall@25` | 0.966 | 0.969 | ─0.24pp |
| **open_domain** | `recall@50` | 0.999 | 0.999 | ─0.00pp |
| **open_domain** | `mrr` | 0.549 | 0.569 | ▲1.99pp |
| **adversarial** | `recall@5` | 0.713 | 0.715 | ─0.22pp |
| **adversarial** | `recall@10` | 0.823 | 0.818 | ─0.45pp |
| **adversarial** | `recall@25` | 0.964 | 0.964 | ─0.00pp |
| **adversarial** | `recall@50` | 1.000 | 1.000 | ─0.00pp |
| **adversarial** | `mrr` | 0.550 | 0.551 | ─0.02pp |

## LoCoMo segment-level  (DRAGON, retrieval-primitive gate)

| scope | metric | v0.2.1 | v0.3.0 | Δ first→latest |
|---|---|---|---|---|
| **OVERALL** | `recall@5` | 0.302 | 0.302 | ─0.00pp |
| **OVERALL** | `recall@10` | 0.366 | 0.366 | ─0.00pp |
| **OVERALL** | `recall@25` | 0.477 | 0.477 | ─0.00pp |
| **OVERALL** | `recall@50` | 0.574 | 0.574 | ─0.00pp |
| **OVERALL** | `mrr` | 0.237 | 0.237 | ─0.00pp |
| **single_hop** | `recall@5` | 0.069 | 0.069 | ─0.00pp |
| **single_hop** | `recall@10` | 0.115 | 0.115 | ─0.00pp |
| **single_hop** | `recall@25` | 0.199 | 0.199 | ─0.00pp |
| **single_hop** | `recall@50` | 0.288 | 0.288 | ─0.00pp |
| **single_hop** | `mrr` | 0.107 | 0.107 | ─0.00pp |
| **multi_hop** | `recall@5` | 0.322 | 0.322 | ─0.00pp |
| **multi_hop** | `recall@10` | 0.394 | 0.394 | ─0.00pp |
| **multi_hop** | `recall@25` | 0.501 | 0.501 | ─0.00pp |
| **multi_hop** | `recall@50` | 0.612 | 0.612 | ─0.00pp |
| **multi_hop** | `mrr` | 0.242 | 0.242 | ─0.00pp |
| **temporal** | `recall@5` | 0.093 | 0.093 | ─0.00pp |
| **temporal** | `recall@10` | 0.173 | 0.173 | ─0.00pp |
| **temporal** | `recall@25` | 0.235 | 0.235 | ─0.00pp |
| **temporal** | `recall@50` | 0.288 | 0.288 | ─0.00pp |
| **temporal** | `mrr` | 0.106 | 0.106 | ─0.00pp |
| **open_domain** | `recall@5` | 0.336 | 0.336 | ─0.00pp |
| **open_domain** | `recall@10` | 0.396 | 0.396 | ─0.00pp |
| **open_domain** | `recall@25` | 0.518 | 0.518 | ─0.00pp |
| **open_domain** | `recall@50` | 0.617 | 0.617 | ─0.00pp |
| **open_domain** | `mrr` | 0.249 | 0.249 | ─0.00pp |
| **adversarial** | `recall@5` | 0.416 | 0.416 | ─0.00pp |
| **adversarial** | `recall@10` | 0.488 | 0.488 | ─0.00pp |
| **adversarial** | `recall@25` | 0.608 | 0.608 | ─0.00pp |
| **adversarial** | `recall@50` | 0.704 | 0.704 | ─0.00pp |
| **adversarial** | `mrr` | 0.320 | 0.320 | ─0.00pp |

## LongMemEval-S  (bge-m3, production methodology)

| scope | metric | v0.2.1 | Δ first→latest |
|---|---|---|---|
| **OVERALL** | `recall@10` | 0.933 | — |
| **OVERALL** | `mrr` | 0.847 | — |