# Visualization Maintenance — benchmarks/viz/

## Files

| File | Purpose |
|---|---|
| `comparison.svg` | Grouped bar chart embedded directly in README.md |
| `data.json` | Source-of-truth for all numbers in the chart |

## How to update when new benchmarks land

1. **Edit `data.json`** — update the `value`, `ci_95`, `run`, and `notes` fields for the system/benchmark that changed.  
   Set `"source": "measured"` for our own runs, `"source": "paper_reported"` for published competitor numbers.

2. **Recompute SVG bar coordinates** using this formula:

   ```
   chart baseline y = 350
   chart top y = 60
   chart height = 290 px (represents 0.0 to 1.0)

   bar_top_y   = 350 - (value * 290)
   bar_height  = value * 290
   ```

   Bar x-positions (do not change unless adding a new system):

   | System | Benchmark | x | width |
   |---|---|---|---|
   | pgmnemo | LoCoMo | 100 | 68 |
   | DRAGON paper range | LoCoMo | 178 | 68 |
   | pgmnemo | LongMemEval | 330 | 68 |
   | BM25 baseline | LongMemEval | 408 | 68 |
   | Competitors (N/A) | LongMemEval | 486 | 68 |
   | pgmnemo MRR | LoCoMo | 590 | 32 |
   | pgmnemo MRR | LongMemEval | 630 | 32 |

3. **Update the value label** (`<text>` element directly above each bar) to match the new number.

4. **Update README.md badges** (`[![LoCoMo recall@10](...)]` and `[![LongMemEval recall@10](...)]`) to reflect the new metric.

5. **Update the text table** in `README.md > ## Benchmarks` section.

6. **Add a `benchmarks/HISTORY.md` entry** documenting the change (source change vs methodology change, delta).

## Adding a new competitor

When Mem0/Zep/MemGPT/MAGMA publish recall@10 on LoCoMo or LongMemEval:

1. Add their number to `data.json` with `"source": "paper_reported"` and a `"paper_url"`.
2. Replace the grey N/A bar block in `comparison.svg` with a colored bar for that system.
3. Add a legend entry for that system's color.
4. Note the paper citation in the SVG footnote and in `docs/BENCHMARKS.md`.

## Adding a new benchmark

Add a new cluster in `comparison.svg` to the right of the LME cluster. Follow the same bar layout pattern. Update `data.json` with the new benchmark object.
