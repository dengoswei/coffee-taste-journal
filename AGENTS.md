# Project Working Rules

## Sol Max Review Gate

Use an independent Sol Max review for every substantive decision involving:

- prompt design, prompt tuning, or prompt-version comparison;
- judge design, rubrics, labels, thresholds, metrics, or evaluation conclusions;
- coffee-profile, recommendation, exploration, or taste/product design.

Before finalizing such a change or treating an evaluation as decision-ready:

1. Freeze or identify the exact prompt, evaluator, weights, labels, and dataset
   version being reviewed.
2. Write acceptance criteria before inspecting the new result. Report
   unweighted results before custom weighted summaries.
3. Prepare a review packet containing the proposed decision, evaluator source,
   current metrics, alternatives, constraints, leakage boundaries, and known
   unknowns.
4. Blind prompt or design identities when comparing alternatives and identity
   could bias the reviewer.
5. Run `python3 scripts/consult_sol_max.py --prepare ... --scope <action>` and
   preserve the returned preregistration path and SHA.
6. Run `python3 scripts/consult_sol_max.py --preregistration <path>
   --preregistration-sha256 <sha>`. A changed preregistration, blocked verdict,
   or malformed verdict returns a non-zero exit code.
7. Run `python3 scripts/verify_sol_max_gate.py <gate.json> --scope <action>`
   before adopting the decision downstream.
8. Read the report under `.generated/sol-max-reviews/`.
9. Record accepted, rejected, and deferred recommendations with reasons in
   `docs/sol-max-review-decisions.md`.
10. Re-run the relevant tests or evaluation after material changes.

Sol Max is an independent critic, not an authority. Verify its factual claims
against the repository and data. Preserve explicit disagreements instead of
silently averaging them away.

A `do not approve` or `approve with conditions` verdict blocks the decision.
Protocol v4 has no automated override. Remediate the conditions and run a new
preregistered review.

Do not send raw personal data by default. The consultation script rejects
inputs under `private/` and `backups/` unless the user explicitly requests
otherwise and `--allow-private` is supplied in both phases. It rejects every
`.generated/` input by default. Move audited aggregate evidence into tracked
`docs/` or `eval/` files before review.

If Sol Max is unavailable, say that the review gate was not completed. Do not
claim that a prompt, judge, or taste-design decision received independent
review.
