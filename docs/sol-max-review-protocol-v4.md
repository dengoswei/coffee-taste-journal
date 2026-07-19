# Sol Max Review Protocol v4

## Scope

Protocol v4 governs substantive prompt tuning, judge/evaluation decisions, and
coffee recommendation or taste-design decisions in this repository.

## Required Flow

1. Prepare a preregistration before the review. It records the exact downstream
   scope, question, acceptance criteria, input hashes, privacy mode, protocol
   specification hash, and runner/verifier source hashes.
2. Run the review only with the exact preregistration SHA emitted by prepare.
3. Use `gpt-5.6-sol` with maximum reasoning in a read-only ephemeral session.
4. Parse the required ordered headings and exact Ship Gate line grammar.
5. Emit an approved gate only for `VERDICT: APPROVE` with exactly `- None`.
6. Verify the report, preregistration, manifests, implementation hashes,
   verdict, and exact downstream scope before adoption.

## Blocking

Malformed, conditional, and rejected reviews block adoption. Protocol v4 has no
automated override mechanism. A blocked decision must be remediated and reviewed
again under a new preregistration.

## Privacy

Inputs under `private/`, `backups/`, or `.generated/` are rejected by default.
Audited aggregate evidence must be moved into tracked `docs/` or `eval/` files.
Private review requires `--allow-private` in both prepare and run phases.

## Versioning

The runner pins this specification by SHA-256 and records runner/verifier source
hashes in every preregistration. Any semantic change to this specification,
review prompt, parser, runner, or verifier requires a new protocol version.
