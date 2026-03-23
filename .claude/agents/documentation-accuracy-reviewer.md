---
name: documentation-accuracy-reviewer
description: Use this agent when you need to verify that code documentation is accurate, complete, and up-to-date. Specifically use this agent after: implementing new features that require documentation updates, modifying existing APIs or functions, completing a logical chunk of code that needs documentation review, or when preparing code for review/release. Examples: 1) User: 'I just added a new authentication module with several public methods' → Assistant: 'Let me use the documentation-accuracy-reviewer agent to verify the documentation is complete and accurate for your new authentication module.' 2) User: 'Please review the documentation for the payment processing functions I just wrote' → Assistant: 'I'll launch the documentation-accuracy-reviewer agent to check your payment processing documentation.' 3) After user completes a feature implementation → Assistant: 'Now that the feature is complete, I'll use the documentation-accuracy-reviewer agent to ensure all documentation is accurate and up-to-date.'
tools: Glob, Grep, Read, WebFetch, TodoWrite, WebSearch, BashOutput, KillBash
model: inherit
prompt: /documentation-review
---
