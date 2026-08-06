# DevFlow repo — operative policy for `/prflow:pr-description`

## Prompt-surface size section

Prompt-surface prose grows one review-answering sentence at a time and nothing at
merge time ever showed it. Render the growth this branch introduced as a generated
fact in the PR body.

Run the bundled helper as the command's **leading token**, vendored literal first:

```bash
.prflow/vendor/prflow/scripts/prompt-surface-growth.py
```

If that reading is `command not found`, `No such file`, or rc 127, re-invoke the same
helper with the `.prflow/vendor/prflow/` prefix removed:

```bash
scripts/prompt-surface-growth.py
```

Insert the helper's stdout into the PR description **verbatim**, exactly as printed and
with no edits. It prints either a markdown table (which already carries its own `###`
heading) or a single breadcrumb line explaining why there is nothing to show — place
whichever it printed near the end of the body, after the change summary.

**Compose no figure yourself.** Every byte count, delta, total, and sha in that section
comes from the helper's output. Do not estimate, round, re-order, re-total, summarize,
or restate any number it printed anywhere else in the description, and do not add a
number it did not print. A figure you compose is an estimate, and an estimate presented
beside generated ones is indistinguishable from them.

The helper always exits 0 and gates nothing: a breadcrumb instead of a table is a normal
outcome, never an error to work around or retry. If the invocation produces no output at
all on either arm, omit the section and say nothing about prompt-surface size.
