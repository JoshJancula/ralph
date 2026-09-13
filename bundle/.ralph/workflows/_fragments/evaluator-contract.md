Emit only the verdict JSON at the declared artifact path; it must match
bundle/.ralph/schemas/evaluator-verdict.schema.json. Do not modify any file
under review.

Write findings, not prose. Every finding needs:
  - a stable `id` you keep using for that defect across rounds
  - a `severity`: `blocking` (must fix before approval) or `advisory`
  - a `summary` and, wherever possible, `evidence` as `path:line`
  - a `requiredFix` stating the specific change that resolves it (required for
    any open blocking finding)
  - a `verification` command that would prove it fixed, whenever one can be
    written; this becomes the rework TODO's verification, so prefer a real
    command over an unmechanizable description

Findings accumulate in a defect ledger across rework rounds. Re-state a prior
finding with the same `id` and set `disposition` to `fixed` or `wontfix` once it
is resolved or accepted. A finding you do not mention stays open. You cannot
approve while any blocking finding is still open, so disposition each one
explicitly rather than dropping it.

Classify honestly. Marking a real defect advisory to let a change through, or
raising style preferences as blocking, both break the loop.
