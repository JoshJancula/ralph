#!/usr/bin/env awk -f
# Lightweight TF-IDF ranker fallback when python3 is unavailable.
# Input lines: filepath:lineno:content
# Output lines: filepath:lineno:content (top max_results by score)

BEGIN {
    split(tolower(query), raw_terms, /[[:space:]]+/)
    term_count = 0
    for (i in raw_terms) {
        t = raw_terms[i]
        gsub(/^[^A-Za-z0-9_]+|[^A-Za-z0-9_]+$/, "", t)
        if (t == "") continue
        seen[t] = 1
        terms[++term_count] = t
    }
    if (term_count == 0) exit 0
    common["function"] = 1
    common["class"] = 1
    common["const"] = 1
    common["let"] = 1
    common["var"] = 1
    common["return"] = 1
    common["import"] = 1
    common["export"] = 1
    common["def"] = 1
    common["the"] = 1
    common["and"] = 1
    common["for"] = 1
}

{
    line = $0
    n = split(line, parts, ":")
    if (n < 3) next
    filepath = parts[1]
    lineno = parts[2]
    content = substr(line, length(filepath) + length(lineno) + 3)
    content_lower = tolower(content)
    path_lower = tolower(filepath)
    base = filepath
    sub(/.*\//, "", base)
    base_lower = tolower(base)

    doc_count++
    docs[doc_count] = line
    paths[doc_count] = filepath
    lines[doc_count] = lineno + 0

    score = 0
    for (i = 1; i <= term_count; i++) {
        t = terms[i]
        if (index(content_lower, t) > 0) {
            tf = gsub(t, t, content_lower)
            if (tf < 1) tf = 1
            idf = log((doc_count + 1) / (tf + 1)) + 1
            if (t in common) idf *= 0.25
            score += tf * idf
        }
        if (index(base_lower, t) > 0) score += 3
        if (index(path_lower, t) > 0) score += 2
        if (content ~ ("(^|[^A-Za-z0-9_])" t "([^A-Za-z0-9_]|$)")) score += 2
        if (content ~ ("(^|[^A-Za-z0-9_])" t "([^A-Za-z0-9_]|$)")) {
            # case-sensitive boost when original-case term appears
            orig = query
            while (match(orig, /[A-Za-z_][A-Za-z0-9_]*/)) {
                token = substr(orig, RSTART, RLENGTH)
                if (tolower(token) == t && index(content, token) > 0) score += 3
                orig = substr(orig, RSTART + RLENGTH)
            }
        }
        if (content ~ /(^|[[:space:]])(function|def|class|export|const|let|var)[[:space:]]/ && index(content_lower, t) > 0) {
            score += 2
        }
    }

    scores[doc_count] = score
    term_hits = 0
    for (i = 1; i <= term_count; i++) {
        if (index(content_lower, terms[i]) > 0) term_hits++
    }
    if (term_hits >= 2) score += 2
    scores[doc_count] = score
}

END {
    if (doc_count == 0) exit 0
    limit = max_results + 0
    if (limit < 1) limit = 50

    for (pass = 1; pass <= doc_count; pass++) {
        best = 0
        best_score = -1
        for (i = 1; i <= doc_count; i++) {
            if (picked[i]) continue
            if (scores[i] > best_score || (scores[i] == best_score && (paths[i] < paths[best] || (paths[i] == paths[best] && lines[i] < lines[best])))) {
                best = i
                best_score = scores[i]
            }
        }
        if (best == 0) break
        print docs[best]
        picked[best] = 1
        if (pass >= limit) break
    }
}
