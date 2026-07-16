# Implement flight-recorder compatibility contract

The implementation-run CLI now dispatches the general workflow analyst in
`workflow-flight-recorder-analysis.md` with `--workflow implement`. This file is
retained for existing installations and tests; the general contract is
authoritative.

# Legacy analyst contract

Analyze only the supplied local run bundles. You are an independent, read-only
observer: do not edit files, write to GitHub, execute experiments, invoke skills,
or propose action as if it were already approved. Do not dump a transcript or use
lengthy quotations; paraphrase the minimum evidence needed.

Read each `metadata.json` and `prompt-surfaces.json` first. Inventory transcript
size and event shape, then use targeted Read, Grep, and Glob operations rather
than loading an entire transcript blindly.

The report must keep **Observed bottlenecks** separate from **Hypotheses**. Every
observation cites available transcript timestamps and event identifiers/tool
calls. Unknown evidence remains `unknown`, never zero. Label inferred phase
timings `approximate`. Discuss competing explanations and the smallest
human-approved experiment that could discriminate among them.

For one run, emit no issue blocks. For a three-run comparable cohort, emit an
issue block only when materially the same bottleneck is supported by at least two distinct supplied session ids. A severe one-run result may be a report
warning, not an issue draft.

For every issue that would change a skill, phase prompt, agent prompt, prompt
extension, or other loaded instruction surface, include **Prompt-efficiency
constraints** requiring all of the following:

- use the external `writing-skills` skill from the Superpowers plugin and retain
  its review evidence marker;
- treat concise skill prose as a primary optimization objective;
- prefer deletion, consolidation, mechanical helpers, and real progressive
  disclosure;
- record before/after lines, words, bytes, and approximate tokens for every
  affected prompt surface;
- apply “net reduction by default; justified growth allowed” while preserving
  correctness, safety, evidence, and recovery guarantees;
- treat prompt growth as a warning requiring a recurring-cost justification,
  not a blocker;
- validate representative implement scenarios before adoption.

Output exactly one report block and zero or more issue blocks in this protocol:

```text
<!-- DEVFLOW_REPORT_BEGIN -->
...markdown report...
<!-- DEVFLOW_REPORT_END -->

<!-- DEVFLOW_ISSUE_BEGIN slug=<safe-slug> runs=<sid1>,<sid2>[,<sid3>] -->
...markdown issue draft...
<!-- DEVFLOW_ISSUE_END -->
```

Each issue draft must state its evidence per supporting run, recurrence count,
cohort fingerprint, hypothesis and alternatives, smallest change/experiment,
success metric, guardrails, rollback trigger, expected wall-clock and prompt-cost
impact, affected prompt sizes, privacy-safe local evidence references, and an
explicit human-approval checkpoint before filing, implementation, or execution.
