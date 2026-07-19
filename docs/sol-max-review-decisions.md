# Sol Max Review Decisions

## 2026-07-17: Prompt, Judge, and Taste Design Baseline

Review artifact:
`.generated/sol-max-reviews/20260717-014345-prompt-judge-and-taste-design.md`

Gate result: **approve with conditions**.

### Accepted

- Treat v1 only as an internal engineering and regression baseline.
- Treat the five historical pairs as a development set because their results
  influenced prompt selection.
- Separate contract-conformance scores from predictive taste validity.
- Add preregistered acceptance criteria, input manifests, blinded comparisons,
  and a blocking-or-explicit-override rule to the Sol Max gate.
- Remove the contradictory metadata exception from the profile prompt and add
  pome fruit to its sensory-family coverage.
- Require sealed cases, adversarial judge tests, repeated-output stability, and
  prospective safe/frontier tasting outcomes before stronger claims.

### Rejected

- None. No recommendation was rejected as incorrect on current evidence.

### Deferred

- Ten or more newly sealed pairwise cases: deferred until new independent
  outcomes are available.
- Blind human claim-support audit: deferred until a representative output
  sample and reviewer protocol are prepared.
- Controlled paired tastings for clarity, acid-sweet balance, and fermentation:
  deferred to prospective data collection.
- Calibration of fit, confidence, expected-liking, and frontier thresholds:
  deferred until enough purchase outcomes exist.

### Current Claim Boundary

v1 is approved for internal implementation and regression detection. It is not
approved as evidence of general recommendation accuracy, calibrated confidence,
validated exploration utility, or stable personal taste preferences.

## 2026-07-17: Gate Enforcement Remediation

Review artifact:
`.generated/sol-max-reviews/20260717-014755-remediation-verification.md`

Gate result: **do not approve**.

### Accepted

- A written policy alone is not an enforceable gate.
- Add a separate timestamped preregistration artifact and reject changed input
  hashes.
- Require a structured Sol Max verdict and return a blocking exit code for
  malformed, conditional, or rejected reviews.
- Add a machine-readable gate artifact and a downstream verifier.
- Require scoped override records with user, timestamp, rationale, review hash,
  and every overridden condition.
- Reject generated raw artifacts by default, not only files stored under
  `private/` or `backups/`.

### Implemented

- `scripts/consult_sol_max.py` now uses a two-phase preregister/run protocol,
  validates hashes, treats source-file instructions as quoted data, parses an
  exact verdict contract, and blocks non-approval.
- `scripts/verify_sol_max_gate.py` validates approved gates or complete scoped
  overrides.
- The privacy gate accepts only redacted `evaluation_summary.md` files from
  `.generated/` unless private access is explicit in both phases.
- End-to-end units cover structured verdict parsing, generated-artifact
  rejection, and override completeness.

### Deferred

- Sol Max verdict-stability measurement and broader prompt-injection testing
  remain future evaluation work. They are not required to run the internal
  engineering gate, but they limit confidence in the reviewer itself.

## 2026-07-17: Protocol v3 Integrity Review

Review artifact:
`.generated/sol-max-reviews/20260717-015533-enforced-gate-final-verification.md`

Gate result: **do not approve**.

### Accepted And Implemented

- Bind execution to the exact SHA-256 emitted during preregistration.
- Reject duplicate, conflicting, additional, or malformed verdict structures.
- Make downstream verification independently validate the gate schema, report
  hash, preregistration hash, protocol, model, conditions, and input manifest.
- Reject empty or invalid overrides and bind an override to the exact requested
  downstream scope.
- Remove the filename-only `.generated/**/evaluation_summary.md` exception.
  Audited aggregate evidence now lives in the tracked
  `eval/coffee_taste/evaluation_summary_20260717.md`.

## 2026-07-17: Ship Gate Grammar Review

Review artifact:
`.generated/sol-max-reviews/20260717-020115-internal-sol-max-gate-adoption.md`

Gate result: **do not approve**.

### Accepted And Implemented

- Replace the multiline regular expression with an exact line grammar.
- Require `## Ship Gate`, one `VERDICT` line, one `CONDITIONS` line, and only
  non-empty bullet lines afterward.
- Add regression tests for duplicate verdicts, content inserted before
  conditions, and non-bullet trailing text.

## 2026-07-17: Invalid Review And Mixed-None Condition

Review artifact:
`.generated/sol-max-reviews/20260717-020440-ship-gate-grammar-final-check.md`

Gate result: **invalid review**, correctly blocked by the parser.

### Accepted And Implemented

- Reject `None` anywhere in a conditional or rejected verdict.
- Allow exactly one optional Markdown blank line after `## Ship Gate`; reject
  blank lines elsewhere in the gate.
- Add regression tests for the optional heading blank line and mixed
  `None` plus concrete conditions.

## 2026-07-17: Blank-Line And Condition-Sentinel Review

Review artifact:
`.generated/sol-max-reviews/20260717-020845-ship-gate-adoption-verdict.md`

Gate result: **do not approve**.

### Accepted And Implemented

- Preserve a normal single final newline but reject a second newline that
  creates a trailing blank line.
- Reject the standalone `None` token anywhere in blocked-condition bullets.
- Add table-driven malformed-gate cases for repeated blanks, duplicate verdict
  or labels, extra headings, invalid approval conditions, and blank lines
  between conditions.
- Add downstream verification coverage for a gate verdict that disagrees with
  its report.

## 2026-07-17: Final Scoped Approval

Review artifact:
`.generated/sol-max-reviews/20260717-021130-final-three-condition-verification.md`

Gate result: **approve**, no conditions.

Downstream verification scope:
`adopt Sol Max protocol v3 for internal prompt, judge, and taste-design decisions`

### Adopted

- Sol Max protocol v3 is the required local review gate for substantive prompt,
  judge/evaluation, recommendation, and taste-design decisions.
- v1 remains an internal engineering/regression baseline only. Predictive taste
  validity still requires sealed and prospective outcomes.

## 2026-07-17: Durable Adoption Review

Review artifact:
`.generated/sol-max-reviews/20260717-021335-durable-protocol-adoption.md`

Gate result: **do not approve**.

### Accepted And Implemented In Protocol v4

- Bind the exact downstream scope into preregistration, report, gate, and
  verifier; reject scope reuse.
- Remove automated overrides instead of accepting unauthenticated user claims.
  Blocked decisions must be remediated and reviewed again.
- Pin a versioned protocol specification by SHA-256 and record runner/verifier
  source hashes in every preregistration. Semantic changes require a new
  protocol version.

## 2026-07-17: Protocol v4 Adoption

Review artifact:
`.generated/sol-max-reviews/20260717-022003-protocol-v4-adoption.md`

Gate result: **approve**, no conditions.

Verified downstream scope:
`adopt Sol Max protocol v4 for internal prompt, judge, evaluation, recommendation, and taste-design decisions`

### Adopted

- Protocol v4 is the durable local review gate for the stated scope.
- A blocked decision has no automated override and must be remediated and
  reviewed again.
- The approved gate remains repeat-verifiable because the append-only decision
  log was not one of its preregistered inputs.
