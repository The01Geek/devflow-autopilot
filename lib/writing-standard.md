# Writing standard for agent-authored content

This page states how the prose that PRFlow's agents write should read. It governs the engineering-facing output — issues, review findings, workpad reflections, PR descriptions, and internal documentation — and it is addressed to the agent composing that prose.

It exists because every other quality mechanism asks whether a claim is defensible, and none asks whether a person can follow it. A draft can be airtight and still unreadable. These rules govern how the prose is arranged, not what it must prove: the evidence a draft carries is unchanged, only its shape is.

## The reader

Write for a competent developer who does not know this codebase. They understand software; they do not know this repository's private terms, its issue numbers, or its internal file layout. A sentence that only makes sense to someone who already read the code has the wrong reader.

## The rules

1. **Name the reader.** Compose for the developer above. When a sentence would only land for someone already steeped in this repository, rewrite it for the reader who is not.

2. **Open plainly.** The opening is scoped by what the artifact is.
   - An artifact that describes a change — an issue, a PR description, a review finding, a release-note entry — opens with two to four sentences saying what is broken and what will change.
   - An artifact that does not describe a change — a reference page, or this standard itself — opens with what the page is for and who it is for.
   - Neither opening uses a repository-private term.

3. **One claim per sentence.** State a single thing per sentence. A second claim goes in its own sentence.

4. **Evidence sits in its own bullet.** Put the support for a claim in a separate bullet, not nested inside the sentence it qualifies. The claim reads first; the evidence follows it.

5. **Define a coined term at first use, and prefer a standard term.** When a word already exists for the thing, use it rather than inventing one. When no word exists and you must coin one, define it where it first appears. Do not invent ALL-CAPS taxonomies, and do not attach serial tags such as `R7`, `META`, or `CORRECTION` — the surrounding structure already classifies the content.

6. **Do not hard-wrap.** Write each paragraph and each bullet as one line and let the renderer wrap it. GitHub and every other markdown renderer reflows prose to the reader's width, so a hand-inserted fixed-column break survives into the rendered output as a ragged short line, and it makes every later edit rewrap the whole paragraph. Line breaks inside a fenced code block are content rather than wrapping, so leave those alone.

## Machine-consumed structure comes first

Some of this content is parsed by tools, not only read by people. An `## Acceptance Criteria` heading, a `- [ ]` checkbox row, an HTML marker block, and a literal cross-reference token such as `PR #<N>` are read by downstream code that matches them exactly. These structures are exempt from the rules above and survive verbatim. When a rule here would push you to reword one of them, the structure wins.
