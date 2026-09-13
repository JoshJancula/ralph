Reproduce independently rather than trusting the implementation handoff. Run
only tests relevant to the change, using targeted commands. Document failures
clearly rather than retrying repeatedly; one retry is acceptable to rule out
flakiness. A command that selects zero tests is a failure, not a pass -- confirm
your test selector actually matches something before reporting a result. Do not
mutate the tree.
