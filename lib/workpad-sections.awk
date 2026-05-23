# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# workpad-sections.awk — Section-level mutations for workpad.sh.
#
# This AWK program is invoked with -v CMD=<command> and additional -v args
# depending on the command. It reads the workpad body on stdin and writes
# the mutated body to stdout. On error it writes to stderr and exits non-zero.
#
# POSIX ERE only — no gawk extensions. No 3-arg match(). Works under mawk
# and BSD awk.
#
# Commands (set via -v CMD=...):
#   split        — split body into sections; emits internal representation
#                  (used only for test / debugging; not used in production)
#   tick         — tick exactly one unticked [ ] checkbox in SECTION matching
#                  SUBSTR (case-insensitive). -v SECTION=... -v SUBSTR=...
#   rewrite      — rewrite one checkbox label in SECTION matching OLDSUBSTR,
#                  replacing label text with NEWTEXT.
#                  -v SECTION=... -v OLDSUBSTR=... -v NEWTEXT=...
#   append_note  — append "- TIMESTAMP — NOTE" to SECTION.
#                  -v SECTION=... -v TIMESTAMP=... -v NOTE=...
#   append_bullet— append "- TEXT" to SECTION.
#                  -v SECTION=... -v TEXT=...
#   set_content  — replace the body of SECTION with the content from
#                  CONTENT_FILE. -v SECTION=... -v CONTENT_FILE=...
#   insert_after — insert a new section with heading NEW_HEADING and content
#                  from CONTENT_FILE immediately after AFTER_SECTION.
#                  -v AFTER_SECTION=... -v NEW_HEADING=... -v CONTENT_FILE=...
#
# Section model (mirrors Python _split_sections / _join_sections):
#   preamble = everything before the first "## " heading.
#   sections  = list of (heading_line, content) pairs; content ends at the
#               start of the next "## " heading or EOF.
#   _join_sections output: preamble.rstrip('\n') joined with section blocks
#   via "\n\n", each block = heading + "\n" + content.rstrip('\n'), final "\n".

# ─── helpers ────────────────────────────────────────────────────────────────

function tolower_ascii(s,    i, c, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "A" && c <= "Z") c = sprintf("%c", index("abcdefghijklmnopqrstuvwxyz", c) + 96)
        out = out c
    }
    return out
}

function rtrim(s,    i) {
    i = length(s)
    while (i > 0 && (substr(s,i,1) == "\n" || substr(s,i,1) == "\r")) i--
    return substr(s, 1, i)
}

# ─── section storage (parallel arrays, 1-indexed) ───────────────────────────
# sec_heading[i], sec_content[i], nsec (count), preamble

# ─── ingest all input into one string ───────────────────────────────────────
BEGIN {
    body = ""
    ORS = ""
}
{ body = body $0 "\n" }

END {
    # Remove trailing newline added by last line (the body itself has a
    # trailing \n we preserve — we add it after the last ORS="" line).
    # Actually just keep body as-is; split_sections handles it.

    split_sections(body)

    if      (CMD == "tick")          do_tick()
    else if (CMD == "rewrite")       do_rewrite()
    else if (CMD == "append_note")   do_append_note()
    else if (CMD == "append_bullet") do_append_bullet()
    else if (CMD == "set_content")   do_set_content()
    else if (CMD == "insert_after")  do_insert_after()
    else { print "workpad-sections.awk: unknown CMD=" CMD > "/dev/stderr"; exit 1 }
}

# ─── split_sections ──────────────────────────────────────────────────────────
function split_sections(b,    i, line, n, lines, in_preamble, cur_heading, cur_content, found) {
    # Split b into lines.
    n = split_to_lines(b, lines)
    preamble = ""
    nsec = 0
    in_preamble = 1
    cur_heading = ""
    cur_content = ""

    for (i = 1; i <= n; i++) {
        line = lines[i]
        if (line ~ /^## /) {
            if (in_preamble) {
                in_preamble = 0
            } else {
                # save previous section
                nsec++
                sec_heading[nsec] = cur_heading
                sec_content[nsec] = cur_content
                cur_content = ""
            }
            cur_heading = line
        } else {
            if (in_preamble) {
                preamble = preamble line "\n"
            } else {
                cur_content = cur_content line "\n"
            }
        }
    }
    # save last section
    if (cur_heading != "") {
        nsec++
        sec_heading[nsec] = cur_heading
        sec_content[nsec] = cur_content
    }
}

# ─── split_to_lines: split string s on \n into arr[1..n]; return n ──────────
function split_to_lines(s, arr,    i, n, rest, pos) {
    n = 0
    rest = s
    # Remove trailing newline so we don't get a spurious empty last element.
    if (substr(rest, length(rest), 1) == "\n")
        rest = substr(rest, 1, length(rest) - 1)
    while (1) {
        pos = index(rest, "\n")
        if (pos == 0) {
            n++
            arr[n] = rest
            break
        }
        n++
        arr[n] = substr(rest, 1, pos - 1)
        rest = substr(rest, pos + 1)
    }
    return n
}

# ─── find_section: return 1-based index or 0 ─────────────────────────────────
function find_section(name,    i, target, heading_lower) {
    target = tolower_ascii("## " name)
    for (i = 1; i <= nsec; i++) {
        heading_lower = tolower_ascii(sec_heading[i])
        # strip trailing whitespace from heading for comparison
        gsub(/[[:space:]]+$/, "", heading_lower)
        if (heading_lower == target) return i
    }
    return 0
}

# ─── join_sections: emit the body ────────────────────────────────────────────
# Mirrors Python's _join_sections exactly:
#   out = [preamble.rstrip('\n')] (if non-empty)
#   for each section: block = heading.rstrip() + '\n' + content
#                     append block.rstrip('\n') to out
#   return '\n\n'.join(out) + '\n'
function join_sections(    i, out, block, sep) {
    out = rtrim(preamble)
    sep = (out != "") ? "\n\n" : ""

    for (i = 1; i <= nsec; i++) {
        block = rtrim(sec_heading[i]) "\n" sec_content[i]
        block = rtrim(block)
        out = out sep block
        sep = "\n\n"
    }
    print out "\n"
}

# ─── tick ────────────────────────────────────────────────────────────────────
function do_tick(    idx, lines, n, i, m, prefix, rest, label, nmatched, match_line,
                     sub_lower, label_lower) {
    idx = find_section(SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk tick: section '## %s' not found\n", SECTION > "/dev/stderr"
        exit 1
    }
    sub_lower = tolower_ascii(SUBSTR)
    n = split_to_lines(sec_content[idx], lines)
    nmatched = 0

    for (i = 1; i <= n; i++) {
        # Match unticked checkbox: ^(\s*[-*]\s+)\[ \](\s+)(.*)$
        if (match(lines[i], /^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]+/)) {
            prefix = substr(lines[i], RSTART, RLENGTH)
            rest   = substr(lines[i], RSTART + RLENGTH)
            # strip the "[ ] " we just matched — prefix already includes it
            # Actually: prefix = bullet+space+"[ ]"+spaces, rest = label text
            label_lower = tolower_ascii(rest)
            if (index(label_lower, sub_lower) > 0) {
                nmatched++
                match_line = i
            }
        }
    }

    if (nmatched == 0) {
        printf "workpad-sections.awk tick: no unticked %s checkbox matched substring %s (already ticked, or no match)\n", \
            SECTION, SUBSTR > "/dev/stderr"
        exit 1
    }
    if (nmatched > 1) {
        printf "workpad-sections.awk tick: %d %s checkboxes match %s; be more specific\n", \
            nmatched, SECTION, SUBSTR > "/dev/stderr"
        exit 1
    }

    # Perform the tick on match_line
    i = match_line
    # We need to replace "[ ]" with "[x]" in the first occurrence on this line.
    # Use index() to find position of "[ ]".
    pos = index(lines[i], "[ ]")
    if (pos > 0) {
        lines[i] = substr(lines[i], 1, pos - 1) "[x]" substr(lines[i], pos + 3)
    }

    # Rebuild content
    sec_content[idx] = ""
    for (i = 1; i <= n; i++) sec_content[idx] = sec_content[idx] lines[i] "\n"

    join_sections()
}

# ─── rewrite ─────────────────────────────────────────────────────────────────
function do_rewrite(    idx, lines, n, i, nmatched, match_line, old_lower, label_lower,
                        prefix, box, spaces, label) {
    idx = find_section(SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk rewrite: section '## %s' not found\n", SECTION > "/dev/stderr"
        exit 1
    }
    old_lower = tolower_ascii(OLDSUBSTR)
    n = split_to_lines(sec_content[idx], lines)
    nmatched = 0

    for (i = 1; i <= n; i++) {
        # Match any checkbox (ticked or not): ^(\s*[-*]\s+)(\[[ xX]\])(\s+)(.*)$
        if (match(lines[i], /^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]+/)) {
            # extract the label portion: everything after the matched prefix
            label = substr(lines[i], RSTART + RLENGTH)
            label_lower = tolower_ascii(label)
            if (index(label_lower, old_lower) > 0) {
                nmatched++
                match_line = i
            }
        }
    }

    if (nmatched == 0) {
        printf "workpad-sections.awk rewrite: no %s checkbox matched %s for rewrite\n", \
            SECTION, OLDSUBSTR > "/dev/stderr"
        exit 1
    }
    if (nmatched > 1) {
        printf "workpad-sections.awk rewrite: %d %s checkboxes match %s; be more specific\n", \
            nmatched, SECTION, OLDSUBSTR > "/dev/stderr"
        exit 1
    }

    # Rewrite the matching line: preserve prefix + box + spaces, replace label.
    i = match_line
    # Re-match to extract parts precisely.
    # prefix = ^(\s*[-*]\s+), box = (\[[ xX]\]), spaces = (\s+)
    if (match(lines[i], /^[[:space:]]*[-*][[:space:]]+/)) {
        prefix = substr(lines[i], RSTART, RLENGTH)
        rest = substr(lines[i], RSTART + RLENGTH)
    }
    # rest now starts with [x] or [ ] etc.
    if (match(rest, /^\[[[:space:]xX]\]/)) {
        box = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
    }
    # rest now starts with spaces before label
    if (match(rest, /^[[:space:]]+/)) {
        spaces = substr(rest, RSTART, RLENGTH)
    }
    lines[i] = prefix box spaces NEWTEXT

    # Rebuild content
    sec_content[idx] = ""
    for (i = 1; i <= n; i++) sec_content[idx] = sec_content[idx] lines[i] "\n"

    join_sections()
}

# ─── append_note ─────────────────────────────────────────────────────────────
function do_append_note(    idx, stripped) {
    idx = find_section(SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk append_note: section '## %s' not found\n", SECTION > "/dev/stderr"
        exit 1
    }
    stripped = rtrim(sec_content[idx])
    if (stripped != "") stripped = stripped "\n"
    sec_content[idx] = stripped "- " TIMESTAMP " \342\200\224 " NOTE "\n"
    join_sections()
}

# ─── append_bullet ───────────────────────────────────────────────────────────
function do_append_bullet(    idx, stripped) {
    idx = find_section(SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk append_bullet: section '## %s' not found\n", SECTION > "/dev/stderr"
        exit 1
    }
    stripped = rtrim(sec_content[idx])
    if (stripped != "") stripped = stripped "\n"
    sec_content[idx] = stripped "- " TEXT "\n"
    join_sections()
}

# ─── set_content ─────────────────────────────────────────────────────────────
function do_set_content(    idx, new_content) {
    idx = find_section(SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk set_content: section '## %s' not found\n", SECTION > "/dev/stderr"
        exit 1
    }
    new_content = read_file(CONTENT_FILE)
    sec_content[idx] = rtrim(new_content) "\n"
    join_sections()
}

# ─── insert_after ────────────────────────────────────────────────────────────
function do_insert_after(    idx, new_content, i) {
    idx = find_section(AFTER_SECTION)
    if (idx == 0) {
        printf "workpad-sections.awk insert_after: section '## %s' not found\n", AFTER_SECTION > "/dev/stderr"
        exit 1
    }
    new_content = read_file(CONTENT_FILE)
    # Shift sections up to make room
    for (i = nsec; i > idx; i--) {
        sec_heading[i + 1] = sec_heading[i]
        sec_content[i + 1] = sec_content[i]
    }
    nsec++
    sec_heading[idx + 1] = NEW_HEADING
    sec_content[idx + 1] = rtrim(new_content) "\n"
    join_sections()
}

# ─── read_file ───────────────────────────────────────────────────────────────
function read_file(path,    line, content, rc) {
    content = ""
    rc = (getline line < path)
    if (rc < 0) {
        printf "workpad-sections.awk: could not read file: %s\n", path > "/dev/stderr"
        exit 1
    }
    if (rc == 0) {
        # empty file
        return ""
    }
    content = line "\n"
    while ((getline line < path) > 0) {
        content = content line "\n"
    }
    close(path)
    return content
}
