# Sol Max Gate Test Result

- Date: `2026-07-17`
- Command: `python3 -m unittest discover -s Tests -p 'test_*.py'`
- Result: `21 tests passed`
- Duration: `0.034s`
- Diff whitespace check: `git diff --check` passed

Covered Sol Max gate behaviors include:

- private and generated input rejection;
- exact preregistration input hashes;
- read-only ephemeral Sol Max invocation;
- exact ordered headings and line-bounded Ship Gate grammar;
- duplicate, conflicting, inserted, trailing, blank-line, and extra-heading
  rejection;
- approval and blocked-condition sentinel rules;
- exact reviewed-scope binding and rejection of scope reuse;
- protocol specification and runner/verifier implementation binding;
- end-to-end report, preregistration, manifest, gate-status, and verdict
  cross-checks;
- rejection after preregistration mutation or gate/report disagreement.
