# Jev window-matching experiment

Standalone synthetic benchmark; does not change the app, deploy a backend, or read the user's windows. API keys stay in ignored local environment files.

```sh
node backend/benchmarks/jev.mjs --check
node --env-file=backend/.env.jev.local backend/benchmarks/jev.mjs
```

The ignored file contains `TYPESAFE_API_KEY`. Optionally set `JEV_BENCHMARK_OUTPUT` to save a JSON report. The baseline mode (`--baseline`) instead requires `VELOCITY_BENCHMARK_ENDPOINT` and `VELOCITY_BENCHMARK_TOKEN` supplied through the environment.

## September 19, 2026 results

Nine fictional windows, nine queries, three repetitions per query. The inventory includes a malicious instruction-like title. Cases cover exact matching, paraphrase, typo, app distinction, profile selection, ambiguity, no match, conversation, and workspace.

| Path | Correct trials | Median | p95 |
| --- | --- | --- | --- |
| Jev (`jev-latest`, direct API) | 27/27 | 153 ms | 626 ms |
| Existing matcher (Gemini 2.5 Flash-Lite through Velocity's Convex endpoint) | 24/27 | 840 ms | 1,437 ms |

Jev consumed 23,136 input tokens. Raw synthetic results are in `results/`.

This measures end-to-end request paths, not isolated model speed: the baseline includes Convex/gateway overhead. Output contracts differ: Jev chooses one existing ID, `none`, or `ambiguous`; the baseline returns ranked IDs. For an ambiguous Gmail query, the baseline passes if both matching profiles occupy the first two positions. Other matching cases evaluate top-1, not the quality of the full returned ranking.

All three baseline misses were the no-match query. This small, hand-written smoke set with repetitions is not a production accuracy or calibration estimate. It does not test hundreds of windows, varied real inventories, arbitrary attacks, regional latency, sustained concurrency, or limits. The experiment supports a larger evaluation before enabling Jev in the product.

API contract: https://docs.typesafe.ai/api

## Integrated multi-result matcher

The production adapter uses independent Jev relevance questions instead of the single-choice experiment above. Run its synthetic regression benchmark:

```sh
node --env-file=.env.jev.local --experimental-strip-types benchmarks/jev.mjs --matcher --large
```

On September 19, 2026, all 27 checks passed with 409 candidates: median 525 ms, p95 640 ms. Results: `results/jev-matcher-409-2026-09-19.json`. This includes 400 synthetic distractors and checks ambiguous searches retain both Gmail profiles. It is a small regression set, not a production accuracy estimate; the 20,000-candidate input ceiling has not been latency-benchmarked. Provider outages or deadline overruns retain local search.
