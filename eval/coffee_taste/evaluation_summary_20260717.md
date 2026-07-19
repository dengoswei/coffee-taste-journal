# Coffee Taste Prompt Evaluation

- Model: `doubao-seed-1-6-flash-250828`
- Historical development cases per version: 5
- Live candidate set is report-only and excluded from tuning labels.

| Version | Pipeline | Raw prompt | Profile | Weighted pairwise | Recommendation contract | Evidence refs |
|---|---:|---:|---:|---:|---:|---:|
| v0 | 0.828 | 0.828 | 0.859 | 0.733 | 0.879 | 0.917 |
| v1 | 0.924 | 0.909 | 1.000 | 0.800 | 0.970 | 1.000 |

## Pairwise Results

| Version | High learnability | Medium | Low | Unweighted |
|---|---:|---:|---:|---:|
| v0 | 2/3 | 1/1 | 1/1 | 4/5 |
| v1 | 3/3 | 0/1 | 0/1 | 3/5 |

## Claim Boundary

- The same five historical pairs informed prompt selection and are now a
  development/regression set, not an untouched test set.
- Contract and evidence-reference scores primarily measure conformance to
  deterministic contracts and grounding rules.
- Weighted pairwise `0.800` is not general recommendation accuracy.
- Prospective liking, calibration, safe-choice regret, exploration utility,
  and serendipity remain unvalidated.
