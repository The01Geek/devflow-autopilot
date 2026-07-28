# slugify.jq — the retrospective pipeline's canonical slug definition, extracted
# to a jq MODULE (issue #891) so both readers share ONE definition:
#   - lib/compute-patterns.jq attributes occurrences and keys its output by it;
#   - lib/compose-filing-key.sh checks a composed filing key round-trips through it.
#
# It lives in a module rather than inline because compute-patterns.jq ends in a
# `reduce` main expression, and jq refuses to `include` a library that carries a
# main expression ("library should only have function definitions"). A module that
# holds ONLY this definition can be `include`d by both readers via `-L lib`, so the
# alternative — a second inline copy in compose-filing-key.sh — never exists, which
# is exactly the uncoupled-mirror drift class #891 removes.
#
# Contract (unchanged from the former inline body): lowercase → collapse every
# non-alphanumeric run to a single `-` → strip leading/trailing `-` → truncate to
# 40 chars → strip a trailing `-` the truncation may have exposed. Every separator
# run collapses to ONE `-`, so a composite key is NOT decomposable after this pass
# (why #891 stores the category on the record instead of encoding it in the key).
#
# slug_kebab is the SAME canonicalization WITHOUT the 40-char truncation, factored
# out so `slugify` is expressed in terms of it (one definition of the lowercase/
# kebab/trim rule, no drift). lib/compose-filing-key.sh reads slug_kebab to measure
# a component's UNTRUNCATED canonical length — the 40-char ceiling decision it makes
# is invisible once slugify has already truncated to 40, so it needs the pre-cap
# form. Everything else uses slugify.
def slug_kebab:
  ascii_downcase
  | gsub("[^a-z0-9]+"; "-")
  | gsub("-+"; "-")
  | ltrimstr("-") | rtrimstr("-");
def slugify:
  slug_kebab
  | .[0:40]
  | rtrimstr("-");
