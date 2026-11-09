# shellcheck shell=bash
# Read-only coordinators, guarded builders.
#
# Coordinators (core, root, a cwd-derived orchestrator) read, plan and ask;
# they never write to a repository. Builders are solo agents: one per product,
# they write, open PRs and land them with `cel solo land`, which checks review
# of the exact head and CI. Reviewers stand outside any workspace (`other`).
#
# The guard limits the CAPABILITY, so a bad prompt - a misread request, a
# confusing inbox message, an invented instruction - produces a refusal, not
# a write.
#
# Sourced by tools/hooks/orchestrator-guard.sh (claude PreToolUse) and by the
# tests. Sources no other library, so the hook stays fast and cannot be taken
# down by unrelated library breakage.
[ -n "${_CEL_GUARD:-}" ] && return 0
_CEL_GUARD=1

# Which role a process is playing, from where it is standing. The SAME
# derivation lib/inbox.sh uses for mail identity, duplicated on purpose: the
# guard must not import inbox state to decide whether to block a command.
#   the core dir                  core         (coordinates; orchestrator-class,
#                                 minus the product agent's verbs)
#   <ws>/repos/<repo>[/...]       orchestrator (reads; the solo agent builds)
#   <ws>/products/<p>[/...]       orchestrator (same powers, same refusals,
#                                 different standpoint)
#   <ws>[/...not under repos]     root
#   anywhere else                 other        (not the plane's concern)
#
# CEL_ROLE=core in the environment says so outright, because core's cwd is a
# plain directory a human could also be standing in - path alone is not
# enough to be sure. CEL_ROLE=solo does the same for a solo agent: it stands
# exactly where an orchestrator stands (the product's directory), so only the
# launch can say which of the two it is. CEL_ROLE=member is a team member
# (`cel run member`): it stands in its team's directory or worktree, which
# path alone would read as root.
guard_role_of() { # <cwd>
  local p="$1"
  # A console launched before its retirement carries CEL_ROLE=console and
  # stands in the old console dir; it is guarded as core, never as `other`.
  case "${CEL_ROLE:-}" in core|console) printf core; return 0;; esac
  # worker|scout|spike are retired fan-out roles; a process still carrying one
  # stays restricted as solo, never `other`.
  case "${CEL_ROLE:-}" in solo|worker|scout|spike) printf solo; return 0;; esac
  case "${CEL_ROLE:-}" in member) printf member; return 0;; esac
  local core="${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"
  local cons="${XDG_DATA_HOME:-$HOME/.local/share}/cel/console"
  case "$p" in "$core"|"$core"/*|"$cons"|"$cons"/*) printf core; return 0;; esac
  local d="$p"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/workspace.yaml" ]; then
      case "$p" in
        "$d"/repos/*|"$d"/products/*) printf orchestrator;;
        *)            printf root;;
      esac
      return 0
    fi
    d="${d%/*}"
  done
  printf other
}

# allow | deny <reason>.
#
# The deny list is EXPLICIT VERBS paired with the thing they mutate, not a
# heuristic about "dangerous-looking" commands. The cost of a false deny is a
# coordinator that has to hand a typo fix to the solo agent; the cost of a
# false allow is an unreviewed write. When in doubt the list errs towards deny,
# and the refusal always says what to do instead.

# An orchestrator owns the STATE of its own checkout, never its authorship:
# nobody else stands over that checkout, so keeping `main` current in it (and
# moving onto a PR branch to run it locally, and back) is its job. Moving
# between refs that ALREADY EXIST creates nothing and discards nothing.
#
# The line: exactly one ref, no flag that creates (-b/-B/-c/-C/--orphan/
# --track/--detach), no `--` or path (that discards working-tree state), and
# nothing that reaches into ANOTHER checkout (-C, --git-dir, --work-tree, or
# a herdr worktree).
_guard_orch_owns_checkout() { # <command> -> 0 = allow
  local c="$1"
  c="${c#"${c%%[![:space:]]*}"}"
  # Reaching into another checkout is never this checkout's state.
  case "$c" in *" -C "*|*--git-dir*|*--work-tree*|*.herdr/worktrees*) return 1;; esac
  # The verb has to BE the command: in a chain, half of it goes unexamined
  # (and a newline is a chain: bash runs the next line as its own command).
  case "$c" in *"&"*|*"|"*|*";"*|*'`'*|*'$('*|*">"*|*"<"*|*$'\n'*) return 1;; esac
  local -a t
  read -r -a t <<<"$c"
  local n=${#t[@]}
  case "${t[0]:-} ${t[1]:-}" in
    "git checkout"|"git switch")
      [ "$n" -eq 3 ] || return 1
      local ref="${t[2]}"
      case "$ref" in -*|.|..|*/) return 1;; esac
      # An existing path is a discard (`git checkout src/x.ts`), not a move.
      [ -e "$ref" ] && return 1
      return 0;;
    "git branch")
      # Lowercase -d only: it refuses to delete unmerged work. -D/-m/-M do not.
      [ "$n" -eq 4 ] && [ "${t[2]}" = "-d" ] || return 1
      case "${t[3]}" in -*) return 1;; esac
      return 0;;
    "gh pr")
      case "${t[2]:-}" in
        checkout)
          # Explicit so that a later tightening of the gh rules below cannot
          # silently regress it.
          [ "$n" -eq 4 ] || return 1
          case "${t[3]}" in -*) return 1;; esac
          return 0;;
        edit)
          # A label is a workflow signal (preview deploy, triage), not PR
          # content. Any other flag is editing somebody else's pull request.
          [ "$n" -ge 5 ] || return 1
          case "${t[3]}" in -*) return 1;; esac
          local i=4
          while [ "$i" -lt "$n" ]; do
            case "${t[$i]}" in
              --add-label|--remove-label)
                i=$((i+1)); [ "$i" -lt "$n" ] || return 1
                case "${t[$i]}" in -*) return 1;; esac;;
              --add-label=*|--remove-label=*) ;;
              *) return 1;;
            esac
            i=$((i+1))
          done
          return 0;;
      esac
      return 1;;
  esac
  return 1
}

# THE COMMANDS A LINE RUNS, READ AS BASH READS THEM: one command per output
# line. Every adapter - the claude hook, omp/pi and OpenCode, all through
# guard-classify.sh - hands the classifier the tool call's command text as it
# is, newlines included, so a newline ends a command here as it does in bash,
# and so do `;`, `&`, `|`, `&&`, `||`, `(`, `)`, `$(...)` and backquotes (a
# redirection's `&`, as in 2>&1 or &>, does not). What bash runs no command
# from is DATA, kept out of the commands:
# - a heredoc body (<<EOF, <<-EOF, <<'EOF') whose reader is a DATA SINK:
#   the command it is given to, and every command that command pipes into,
#   is one of cat, tee, cel, read, jq, yq, echo, printf, wc, head, tail,
#   uniq, cut, tr, grep, rg, diff, cmp, base64, the sha/md5 sums, column,
#   fold, fmt, nl, tac, rev, paste, iconv, mapfile/readarray (without -C),
#   `git commit -F -`/`--file=-` and `gh ... --body-file -`/`-F -` - and no
#   file it writes (`>`, `>>`, tee) is run anywhere in the line (named as a
#   command, or handed to chmod, a shell, source, `.`, an interpreter, awk,
#   xargs, crontab or at). Only the $(...) and backquotes an unquoted one
#   expands are commands. Any other reader - a shell, python, node, perl,
#   `$SHELL`, `while read l; do $l; done` - makes the body commands;
# - a newline inside a quoted string ('...', "...", $'...' and its \n,
#   \x0a, \012 or \cj) is a space (with <join>, nothing: a path split across
#   lines) - unless the string is code for a shell (`bash -c`, `sh -c`, `su
#   -c`, `flock -c`, eval, ssh, watch), when it and the string's own `;`, `&`,
#   `|`, `(` and `)` end a command;
# - a comment is dropped, and a backslash before a newline joins the lines.
# Arithmetic - $((...)), ((...)), $[...] and a [...] subscript - opens no
# heredoc. A line this reading cannot be sure of - a quote, an expansion or a
# heredoc left open, a heredoc opened inside a heredoc, a heredoc delimiter
# with `$`, `[` or `]` in it, a `<<` inside a word's [...] - is read the
# cautious way instead: every newline and separator ends a command and
# nothing is data.
read -r -d '' _GUARD_LINES_AWK <<'AWK' || :
# A heredoc body that is data is quiet: only the commands its $(...) and
# backquotes run are written out.
function emit(x) { if (!qt[d]) { out = out x; cur[cl[d]] = cur[cl[d]] x } }
# A command ends; <sep> is what ended it ("|" a pipe, "n" a newline).
function brk(sep) { out = out "\n"; nseg++; ssep[nseg] = sep; cur[cl[d]] = ""; ws = 1; wb = 0 }
function push(t, code, closer) {
  d++; st[d] = t; cf[d] = code; pc[d] = 0; ac[d] = closer
  if (t == "T" || t == "C" || t == "B" || t == "A") { cl[d] = d; cur[d] = ""; qt[d] = 0 } else { cl[d] = cl[d - 1]; qt[d] = t == "H" || qt[d - 1] }
}
function pop() { if (d > 0) d--; else bad = 1 }
# Does the command so far hand its next quoted word to a shell as code?
function iscode(x) {
  gsub(/[\047"\\]/, "", x)
  if (x ~ /(^|[^A-Za-z0-9_.-])(ba|z|da|k|mk|a)?sh([ \t].*)?[ \t]-[A-Za-z]*c/) return 1
  if (x ~ /(^|[^A-Za-z0-9_.-])(su|flock|script)([ \t].*)?[ \t](-[A-Za-z]*c|--command)/) return 1
  return x ~ /(^|[^A-Za-z0-9_.-])(eval|ssh|watch)([ \t]|$)/
}
function words(x) { gsub(/[\047"\\]/, "", x); gsub(/[ \t]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
# The word a command runs: past assignments, keywords and wrappers.
function firstword(x,   n, a, i) {
  n = split(words(x), a, " "); i = 1
  while (i <= n) {
    if (a[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || a[i] ~ /^(if|then|else|elif|do|done|while|until|fi|!|\{|\}|time)$/) { i++; continue }
    if (a[i] ~ /^(.*\/)?(sudo|doas|env|command|builtin|exec|nohup|nice|ionice|setsid|stdbuf|timeout)$/) {
      i++; while (i <= n && (a[i] ~ /^-/ || a[i] ~ /^[0-9.]+[smhd]?$/)) i++
      continue
    }
    break
  }
  return i <= n ? a[i] : ""
}
function base(w) { sub(/^.*\//, "", w); return w }
# Is this command a data sink for a heredoc it reads?
function sink(x,   w) {
  w = words(x); sub(/ .*/, "", w)
  if (w == "for" || w == "select") return 1
  w = base(firstword(x))
  if (w == "") return 1
  if (w ~ /^(cat|tee|cel|cel-linear|read|jq|yq|echo|printf|true|:|wc|head|tail|uniq|cut|tr|grep|egrep|fgrep|rg|diff|cmp|base64|sha1sum|sha256sum|sha512sum|md5sum|column|fold|fmt|nl|tac|rev|paste|iconv)$/) return 1
  x = " " words(x) " "
  if (w == "mapfile" || w == "readarray") return x !~ / -[A-Za-z]*C/
  if (w == "git") return x ~ / commit / && x ~ /( -F ?-|--file[= ]-) /
  if (w == "gh") return x ~ /(--body-file[= ]-| -F ?-) /
  return 0
}
# The files a command writes, by base name: > >> >| targets and tee's.
function targets(x,   n, a, i, w, t, tee, r) {
  n = split(words(x), a, " "); tee = base(firstword(x)) == "tee"; r = ""
  for (i = 1; i <= n; i++) {
    w = a[i]; t = ""
    if (w ~ /^[0-9]*>[>|]?$/) t = a[i + 1]
    else if (w ~ /^[0-9]*>[>|]?[^&]/) { t = w; sub(/^[0-9]*>[>|]?/, "", t) }
    else if (tee && w !~ /^-/ && base(w) != "tee") t = w
    if (t != "") r = r " " base(t)
  }
  return r
}
# Does this command run the file <t> (or hand it to something that does)?
function executes(x, t,   n, a, i, w) {
  w = base(firstword(x))
  if (w == t) return 1
  if (w !~ /^(chmod|bash|sh|zsh|dash|ksh|mksh|ash|fish|csh|tcsh|source|\.|python[0-9.]*|perl|ruby|node|nodejs|php|deno|bun|awk|gawk|mawk|nawk|crontab|at|batch|eval|xargs|install)$/) return 0
  n = split(words(x), a, " ")
  for (i = 2; i <= n; i++) if (base(a[i]) == t) return 1
  return 0
}
# Heredoc k's body is data when its reader, and all it pipes into - a whole
# compound command (while ... done, if ... fi, { ... }, ( ... )) included -
# are sinks.
function datasink(k,   j, r, w, depth) {
  r = ""; depth = 0
  for (j = hseg[k]; j <= nseg; j++) {
    if (!sink(S[j])) return 0
    r = r targets(S[j])
    w = words(S[j]); sub(/ .*/, "", w)
    if (w ~ /^(while|until|for|select|if|case|\{)$/) depth++
    else if (w ~ /^(done|fi|esac|\})$/) depth--
    if (ssep[j] == "(") depth++
    else if (ssep[j] == ")") depth--
    if (depth <= 0 && ssep[j] != "|") { tg[hid[k]] = r; return 1 }
    if (ssep[j] == "|" && S[j + 1] ~ /^[ \t]*$/ && ssep[j + 1] == "n") return 0
  }
  return 0
}
function num(h, b,   i, v) {
  v = 0
  for (i = 1; i <= length(h); i++) v = v * b + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
  return v
}
# The length of the $'...' escape at x[i] when it is a newline, else 0.
function escnl(x, i,   r) {
  r = substr(x, i + 1, 9)
  if (r ~ /^n/) return 2
  if (r ~ /^c[jJ]/) return 3
  if (match(r, /^x[0-9A-Fa-f][0-9A-Fa-f]?/) || match(r, /^u[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?/) \
      || match(r, /^U[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?/))
    return num(substr(r, 2, RLENGTH - 1), 16) == 10 ? RLENGTH + 1 : 0
  if (match(r, /^[0-7][0-7]?[0-7]?/)) return num(substr(r, 1, RLENGTH), 8) == 10 ? RLENGTH + 1 : 0
  return 0
}
# A heredoc operator at x[i] (`<<` or `<<-`, then its word): the index of its
# last character, with HW its delimiter, HQ whether it is quoted, HS `<<-`;
# a delimiter with $, [ or ] in it (`$'EOF'`, `2]`) sets bad.
function heredoc(x, i,   j, m, c, w, q, k) {
  m = length(x); j = i + 2; HS = 0
  if (substr(x, j, 1) == "-") { HS = 1; j++ }
  while (j <= m && substr(x, j, 1) ~ /[ \t]/) j++
  w = ""; q = 0
  while (j <= m) {
    c = substr(x, j, 1)
    if (c ~ /[ \t;&|()<>]/) break
    if (c ~ /[$\[\]]/) bad = 1
    if (c == "\047" || c == "\"") {
      k = index(substr(x, j + 1), c); if (!k) return 0
      q = 1; w = w substr(x, j + 1, k - 1); j += k + 1; continue
    }
    if (c == "\\") { q = 1; w = w substr(x, j + 1, 1); j += 2; continue }
    w = w c; j++
  }
  if (w == "" && !q) return 0
  HW = w; HQ = q
  return j - 1
}
function hstart() {
  hmode = hc[hk] ? "code" : hq[hk] ? "skip" : "expand"
  if (hmode == "expand") push("H", 0, "")
  hdp = d
}
function lex(   li, line, m, cont, ci, c, nx, pv, t, k, b) {
  split("", st); split("", cf); split("", pc); split("", ac); split("", cl); split("", cur); split("", qt)
  split("", hd); split("", hq); split("", hs); split("", hid); split("", hseg); split("", hc); split("", ssep); split("", tg)
  d = 0; st[0] = "T"; cf[0] = 0; pc[0] = 0; cl[0] = 0; cur[0] = ""; qt[0] = 0; ws = 1; wb = 0; out = ""
  nh = 0; hn = 0; hact = 0; bad = 0; nseg = 0
  for (li = 1; li <= nl; li++) {
    line = L[li]; m = length(line); cont = 0
    if (hact) {
      b = line; if (hs[hk]) sub(/^\t+/, "", b)
      if (b == hd[hk] && d == hdp) {
        if (hmode == "expand") pop()
        brk("n")
        if (++hk > nh) { hact = 0; nh = 0 } else hstart()
        continue
      }
      if (hmode == "skip") continue
    }
    for (ci = 1; ci <= m; ci++) {
      c = substr(line, ci, 1); nx = substr(line, ci + 1, 1); pv = ci > 1 ? substr(line, ci - 1, 1) : ""; t = st[d]
      # quoted text: a separator in one handed to a shell as code ends a command
      if (t == "S" || t == "Q" || t == "D") {
        if (cf[d] && (c == ";" || c == "|" || c == "(" || c == ")" || (c == "&" && nx != ">" && pv != ">" && pv != "<"))) { brk(c); continue }
      }
      if (t == "S") { if (c == "\047") pop(); emit(c); continue }
      if (t == "Q") {
        if (c == "\047") { pop(); emit(c); continue }
        if (c == "\\") {
          k = escnl(line, ci)
          if (k) { if (cf[d]) brk(";"); else emit(J); ci += k - 1; continue }
          emit(c nx); ci++; continue
        }
        emit(c); continue
      }
      if (c == "\\") {
        if (ci == m && li < nl && t != "P") { cont = 1; break }
        emit(c nx); ci++; ws = 0; continue
      }
      # expansions open in commands, double quotes, heredoc bodies and ${...}
      if (c == "$" && nx == "(" && substr(line, ci + 2, 1) == "(") { emit("$(("); push("A", 0, ")"); ci += 2; continue }
      if (c == "$" && nx == "[") { emit("$["); push("A", 0, "]"); ci++; continue }
      if (c == "$" && nx == "(") { emit("$("); push("C", 0, ")"); brk("("); ci++; continue }
      if (c == "$" && nx == "{") { emit("${"); push("P", 0, "}"); ci++; ws = 0; continue }
      if (c == "`") {
        if (t == "B") { brk("`"); pop(); emit(c); ws = 0 } else { emit(c); push("B", 0, "`"); brk("`") }
        continue
      }
      if (t == "D" || t == "H") {
        if (c == "\"" && t == "D") pop()
        emit(c); continue
      }
      if (t == "P") {
        if (c == "}") pop()
        else if (c == "\"") push("D", 0, "\"")
        else if (c == "\047" && st[d - 1] != "D" && st[d - 1] != "H") push("S", 0, "\047")
        emit(c); continue
      }
      if (t == "A") {
        if (ac[d] == "]") {
          if (c == "[") pc[d]++
          else if (c == "]") { if (pc[d] > 0) pc[d]--; else { emit(c); pop(); ws = 0; continue } }
        } else if (c == "(") pc[d]++
        else if (c == ")") {
          if (pc[d] > 0) pc[d]--
          else if (nx == ")") { emit("))"); pop(); ci++; ws = 0; continue }
        }
        emit(c); continue
      }
      # a command: T (the line), C ($(...)), B (`...`)
      if (c == "\047") { push("S", iscode(cur[cl[d]]), "\047"); emit(c); ws = 0; continue }
      if (c == "$" && nx == "\047") { push("Q", iscode(cur[cl[d]]), "\047"); emit("$\047"); ci++; ws = 0; continue }
      if (c == "\"") { push("D", iscode(cur[cl[d]]), "\""); emit(c); ws = 0; continue }
      if (c == "#" && ws) break
      if (c == "(" && nx == "(" && ws) { emit("(("); push("A", 0, ")"); ci++; continue }
      if (c == "<" && nx == "<") {
        if (substr(line, ci + 2, 1) == "<") { emit("<<<"); ci += 2; ws = 1; wb = 0; continue }
        # inside a word's [...] (`x[1<<2]=3`) it is arithmetic: be cautious
        if (wb > 0) bad = 1
        k = heredoc(line, ci)
        if (k) {
          if (hact) bad = 1
          nh++; hn++; hd[nh] = HW; hq[nh] = HQ; hs[nh] = HS; hid[nh] = hn; hseg[nh] = nseg + 1
          emit(substr(line, ci, k - ci + 1)); ci = k; ws = 0; continue
        }
        emit("<<"); ci++; ws = 1; wb = 0; continue
      }
      if (c == "&" && (nx == ">" || pv == ">" || pv == "<")) { emit(c); ws = 1; wb = 0; continue }
      if (c == "|") { if (nx == "|") { brk("o"); ci++ } else { if (nx == "&") ci++; brk("|") } continue }
      if (c == "&") { if (nx == "&") { brk("o"); ci++ } else brk("&"); continue }
      if (c == ";") { brk(";"); continue }
      if (c == "(") { pc[d]++; brk("("); continue }
      if (c == ")") {
        if (t == "C" && pc[d] == 0) { brk(")"); pop(); emit(c); ws = 0; continue }
        if (pc[d] > 0) pc[d]--
        brk(")"); continue
      }
      if (c == "[") wb++
      else if (c == "]" && wb > 0) wb--
      emit(c)
      if (c == " " || c == "\t" || c == "<" || c == ">") { ws = 1; wb = 0 } else ws = 0
    }
    if (li == nl || cont) continue
    # the end of a line
    t = st[d]
    if (t == "S" || t == "Q" || t == "D" || t == "H" || t == "P") { if (cf[d]) brk("n"); else emit(J); continue }
    if (t == "A") { emit(" "); continue }
    brk("n")
    if (nh > 0 && !hact) {
      split(out, S, "\n")
      for (k = 1; k <= nh; k++) hc[k] = (hid[k] in force) || !datasink(k)
      hact = 1; hk = 1; hstart()
    }
  }
}
# Is a file a data heredoc wrote run anywhere in the line? Then that body is
# commands: read the line again with it so.
function rerun(   n, a, h, nt, T, i, j, again) {
  if (bad) return 0
  n = split(out, a, "\n"); again = 0
  for (h in tg) {
    if (h in force) continue
    nt = split(tg[h], T, " ")
    for (i = 1; i <= nt && !(h in force); i++)
      for (j = 1; j <= n; j++) if (executes(a[j], T[i])) { force[h] = 1; again = 1; break }
  }
  return again
}
{ s = NR > 1 ? s "\n" $0 : $0 }
END {
  nl = split(s, L, "\n")
  for (pass = 0; pass < 8; pass++) { lex(); if (!rerun()) break }
  # not sure of it: every newline and separator ends a command
  if (bad || d != 0 || hact || pass == 8) {
    gsub(/\\\n/, "", s)
    gsub(/[;&|()`\n]+|\$[([]/, "\n", s)
    out = s
  }
  printf "%s", out
}
AWK
_guard_lines() { # <command> [join] -> the commands it runs, one per line
  # If the reader itself fails, the cautious split: never an empty, allowed line.
  local s
  s="$(printf '%s' "$1" | LC_ALL=C awk -v J="${2- }" "$_GUARD_LINES_AWK" 2>/dev/null)" && { printf '%s' "$s"; return 0; }
  s="${1//$'\\\n'/}"; s="${s//\$\(/$'\n'}"; s="${s//\$\[/$'\n'}"
  printf '%s' "${s//[;&|()\`]/$'\n'}"
}

# THE COMMANDS A SHELL LINE WOULD RUN, one per line, each reduced to the verb
# that would execute. A substring test on the raw text is evaded by spacing,
# quotes, global options before the verb or a chain (`cd x && ...`), and
# refuses `grep "cel solo land"`. So the line is split where a new command
# starts (a newline, `;`, `&`, `|`, `(`, `)`, `$(`, backtick - inside quotes
# too, which errs towards deny: guard_classify hands it _guard_lines' reading,
# where a heredoc or quoted body is data already), quotes are dropped,
# whitespace is collapsed, and from the front of each piece go: env
# assignments, the keywords a script puts in front of a command (if, then,
# else, elif, do, while, until, !, {, }), wrappers given by name or by path
# (bash/sh -c, env, command, exec, nohup, time, xargs, sudo/doas,
# nice/ionice, stdbuf, setsid, timeout N) together with their options and
# the values of the ones that take one
# (`env -u X`, `xargs -n 1`, `xargs -I {}`, `sudo -u root`), a path in front
# of cel/gh/herdr/tea/curl, and the global options between a tool and its
# verb (`-C`/`--workspace` for cel, `-R`/`--repo` for gh). The rules then
# match the START of a piece only.
#
# A TRIPWIRE, NOT A SANDBOX (docs/architecture.md): a variable holding the
# command (`c=cel; $c solo land`) or a script file still runs. What this
# stops is the plausible mistake, spelled any of the ways an agent writes it.
_guard_segments() { # <command> -> one normalised command per line
  printf '%s' "$1" | sed -E 's/\$\(/;/g; s/[`();|&]+/\n/g' | _guard_normalise
}
# The normalising half, line for line: one command in, its verb out.
_guard_normalise() { # stdin: one command per line -> each normalised, on its line
  tr '\t\r' '  ' | sed -E 's/["'"'"']//g; s/ +/ /g; s/^ //; s/ $//
    :a
    s#^[A-Za-z_][A-Za-z0-9_]*=[^ ]* ##; ta
    s#^(if|then|else|elif|do|while|until|!|\{|\})( |$)##; ta
    s#^[^ ]*/(bash|sh|env|command|exec|nohup|time|xargs|sudo|doas|nice|ionice|stdbuf|setsid|timeout)( |$)#\1\2#; ta
    s#^(bash|sh|command|nohup|setsid)( (-o [^ ]+|-[^ ]+))* ##; ta
    s#^env( (-[uC] [^ ]+|--(unset|chdir) [^ ]+|-[^ ]+))* ##; ta
    s#^exec( (-a [^ ]+|-[^ ]+))* ##; ta
    s#^time( (-[fo] [^ ]+|-[^ ]+))* ##; ta
    s#^xargs( (-[adEILnPs] [^ ]+|--(arg-file|delimiter|eof|replace|max-lines|max-args|max-procs|max-chars|process-slot-var) [^ ]+|-[^ ]+))* ##; ta
    s#^(sudo|doas)( (-[ugCDhprtTU] [^ ]+|--(user|group|close-from|chdir|host|prompt|role|type|other-user|command-timeout) [^ ]+|-[^ ]+))* ##; ta
    s#^(nice|ionice)( (-[nct] [^ ]+|--adjustment [^ ]+|-[^ ]+))* ##; ta
    s#^stdbuf( (-[ioe] [^ ]+|-[^ ]+))* ##; ta
    s#^timeout( (-[sk] [^ ]+|-[^ ]+))* [0-9.]+[smhd]? ##; ta
    s#^[^ ]*/(cel|gh|herdr|tea|curl|git)( |$)#\1\2#
    :b
    s#^cel (-C [^ ]+|--workspace[= ][^ ]+)( |$)#cel\2#; tb
    s#^gh (-R [^ ]+|--repo[= ][^ ]+)( |$)#gh\2#; tb'
}

# Does any command in the line start with one of these (extended) patterns?
_guard_starts() { # <command> <ERE...> -> 0 when one does
  local cmd="$1"; shift
  local seg p
  while IFS= read -r seg || [ -n "$seg" ]; do
    for p in "$@"; do
      [[ "$seg" =~ ^($p)( |$) ]] && return 0
    done
  done < <(_guard_segments "$cmd")
  return 1
}

# A FORGE CHANGED BY HAND: curl writing to a Forgejo (/api/v1/) or GitHub
# (api.github.com) API, `tea api` with anything but a plain GET, or one of
# tea's write verbs. `cel forge` and the land doors are the sanctioned paths;
# these are the same writes with every check skipped.
_guard_forge_raw_write() { # <command> -> 0 when a piece writes to a forge by hand
  local seg
  while IFS= read -r seg || [ -n "$seg" ]; do
    case "$seg" in
      curl|curl\ *) _guard_curl_writes "$seg" && return 0 ;;
      tea\ *) _guard_tea_writes "$seg" && return 0 ;;
    esac
  done < <(_guard_segments "$1")
  return 1
}

# curl at a forge API that writes: a request body in any spelling (-d@x, -dX,
# --data*, --json, -F/--form*, -T/--upload-file), a method other than GET or
# HEAD in any spelling (-X M, -XM, -sXM, --request[=]M), or options read from
# a file (-K/--config), which could carry either. Short options are walked
# letter by letter: one that takes a value ends its group (`-oFILE`).
_guard_curl_writes() { # <segment>
  local seg="$1" w c i j n method="" write=0
  [[ "$seg" == */api/v1/* || "$seg" == *api.github.com* ]] || return 1
  local -a t; read -r -a t <<<"$seg"; n=${#t[@]}
  for ((i = 1; i < n; i++)); do
    w="${t[i]}"
    case "$w" in
      --request=*) method="${w#--request=}" ;;
      --request) method="${t[i+1]:-}" ;;
      --data|--data[=-]*|--json|--json=*|--form|--form[=-]*|--upload-file|--upload-file=*|--config|--config=*) write=1 ;;
      --*) ;;
      -?*)
        for ((j = 1; j < ${#w}; j++)); do
          c="${w:j:1}"
          case "$c" in
            d|F|T|K) write=1; break ;;
            X) method="${w:j+1}"; [ -n "$method" ] || method="${t[i+1]:-}"; break ;;
            [HouAebcxwrmEyYzCDPQtU]) break ;;
          esac
        done ;;
    esac
  done
  [ "$write" = 0 ] || return 0
  case "${method^^}" in ""|GET|HEAD) return 1 ;; esac
  return 0
}

# tea: `tea api` unless it is a plain GET with no body, and the write verbs
# of pulls, releases, repos and branches - read past tea's own options (and
# the values of the ones that take one) to find the verb.
_guard_tea_writes() { # <segment>
  local -a t words; read -r -a t <<<"$1"
  mapfile -t words < <(_guard_tea_words "$1")
  local i n=${#t[@]} w
  case "${words[0]:-}" in
    api)
      local method=""
      for ((i = 1; i < n; i++)); do
        w="${t[i]}"
        case "$w" in
          -X|--method) method="${t[i+1]:-}" ;;
          --method=*) method="${w#--method=}" ;;
          -X?*) method="${w#-X}" ;;
          -f|-F|-d|--field|--field=*|--raw-field|--raw-field=*|--data|--data=*|--input|--input=*|-f?*|-F?*|-d?*) return 0 ;;
        esac
      done
      case "${method^^}" in ""|GET) return 1 ;; esac
      return 0 ;;
    pr|pulls|pull)
      case "${words[1]:-}" in merge|m|close|create|c|reopen|open|edit|e|approve|lgtm|a|reject|review) return 0 ;; esac ;;
    release|releases|r)
      case "${words[1]:-}" in create|c|delete|rm|edit|e) return 0 ;; esac ;;
    repo|repos)
      case "${words[1]:-}" in create|fork|delete|migrate|edit) return 0 ;; esac ;;
    branch|branches|b)
      case "${words[1]:-}" in protect|P|unprotect|U) return 0 ;; esac ;;
  esac
  return 1
}

# tea's words: the verb and its arguments, read past tea's own options (and
# the values of the ones that take one).
_guard_tea_words() { # <segment> -> one word per line
  local -a t; read -r -a t <<<"$1"
  local i n=${#t[@]} w
  for ((i = 1; i < n; i++)); do
    w="${t[i]}"
    case "$w" in
      --repo|-r|--login|-l|--remote|-R|--output|-o) i=$((i + 1)) ;;
      -*) ;;
      *) printf '%s\n' "$w" ;;
    esac
  done
}

# A FORGE REVIEW VERDICT IS A PERSON'S. An approval or a request for changes
# posted to the forge reads as a human's code review (lib/solo.sh lets one
# stand in for the recorded verdict), so no agent posts one, in any role:
# - `gh pr review` with --approve/-a or --request-changes/-r (flags after the
#   PR, `--approve=...`, a short group such as `-cr`; the value of -b/-F/-R
#   is skipped);
# - a gh api write to a PR's reviews (`.../pulls/<n>/reviews` and below it:
#   events, dismissals; `repos/<o>/<r>/` or `repositories/<id>/` in front);
# - `gh api graphql` that names add/submit/dismiss of a PullRequestReview, or
#   whose query the guard cannot read: `--input`, a field value from a file
#   (`query=@q.graphql`), an expansion (`$Q`) or one cut off by `$(...)`;
# - curl writing to that path on a forge API;
# - tea's approve (lgtm, a), reject and review, and `tea api` writing to that
#   path. Every prefix of those verbs and of `pulls` counts too (`tea pr r`):
#   tea's own alias table (cmd/pulls/*.go) has only lgtm and a, but its CLI
#   library can match commands by prefix.
# A path is read percent-decoded, case-folded, with doubled slashes squeezed
# and a `#fragment` ignored. The line is read as bash reads it (_guard_lines:
# a newline ends a command, a heredoc body is data), and once more with the
# newlines inside its quoted strings removed (a path split across lines).
# A comment is not a verdict. Quotes are dropped by _guard_segments, so a
# comment body that itself spells `-a` after `gh pr review` is refused too:
# the guard errs towards deny.
_GUARD_FORGE_REVIEWS_RE='(^|/)pulls/[^/]+/reviews([/?#]|$)'
_guard_reviews_path() { # <word> -> 0 when it names a PR's reviews (or below)
  local w="${1,,}"
  while [[ "$w" == *//* ]]; do w="${w//\/\//\/}"; done
  [[ "$w" =~ $_GUARD_FORGE_REVIEWS_RE ]]
}
# The prefixes of tea's verdict verbs: what `tea pulls <word>` may resolve to.
_guard_tea_verdict_word() { # <word>
  local v
  [ -n "$1" ] || return 1
  for v in approve lgtm reject review; do [[ "$v" == "$1"* ]] && return 0; done
  return 1
}
_guard_forge_verdict() { # <command> -> 0 when a piece posts a forge review verdict
  local s j
  s="$(_guard_lines "$1")"
  _guard_forge_verdict_decoded "$s" && return 0
  [[ "$1" == *[$'\n\r']* ]] || return 1
  j="$(_guard_lines "${1//$'\r'/}" "")"
  [ "$j" != "$s" ] && _guard_forge_verdict_decoded "$j"
}
_guard_forge_verdict_decoded() { # <commands> -> as written, then %XX-decoded
  local s="$1" h
  _guard_forge_verdict_in "$s" && return 0
  # %XX decoded: `pulls/5/%72eviews` is the same path to the forge
  while [[ "$s" =~ %([0-9A-Fa-f]{2}) ]]; do
    printf -v h "\\x${BASH_REMATCH[1]}"
    s="${s//"${BASH_REMATCH[0]}"/"$h"}"
  done
  [ "$s" != "$1" ] && _guard_forge_verdict_in "$s"
}
_guard_forge_verdict_in() { # <command>
  local seg w c i j n v graphql
  local -a t words
  while IFS= read -r seg || [ -n "$seg" ]; do
    read -r -a t <<<"$seg"; n=${#t[@]}
    case "$seg" in
      "gh pr "*)
        i=2
        while [ "$i" -lt "$n" ]; do
          case "${t[i]}" in -R|--repo) i=$((i + 2)) ;; -R?*|--repo=*) i=$((i + 1)) ;; *) break ;; esac
        done
        [ "${t[i]:-}" = review ] || continue
        for ((i = i + 1; i < n; i++)); do
          w="${t[i]}"
          case "$w" in
            --approve|--approve=*|--request-changes|--request-changes=*) return 0 ;;
            --body|--body-file|--repo) i=$((i + 1)) ;;
            --*) ;;
            -?*)
              for ((j = 1; j < ${#w}; j++)); do
                c="${w:j:1}"
                case "$c" in
                  a|r) return 0 ;;
                  b|F|R) [ "$j" -lt $((${#w} - 1)) ] || i=$((i + 1)); break ;;
                esac
              done ;;
          esac
        done ;;
      "gh api "*)
        [[ "$seg" =~ (add|submit|dismiss)PullRequestReview([^A-Za-z]|$) ]] && return 0
        graphql=0
        for w in "${t[@]:2}"; do case "${w,,}" in graphql|*/graphql|*/graphql\?*) graphql=1 ;; esac; done
        if [ "$graphql" = 1 ]; then
          for ((i = 2; i < n; i++)); do
            w="${t[i]}"; v=""
            case "$w" in
              --input|--input=*) return 0 ;;
              -f|-F|--field|--raw-field) v="${t[i+1]-}"; i=$((i + 1)) ;;
              --field=*|--raw-field=*) v="${w#*=}" ;;
              -f?*|-F?*) v="${w:2}" ;;
              *) continue ;;
            esac
            [[ "$v" == *=* ]] || return 0
            v="${v#*=}"
            case "$v" in ""|@*|*\$*) return 0 ;; esac
          done
        fi
        _guard_gh_api_writes "$seg" || continue
        for w in "${t[@]:2}"; do _guard_reviews_path "$w" && return 0; done ;;
      curl\ *)
        _guard_curl_writes "$seg" || continue
        for w in "${t[@]:1}"; do _guard_reviews_path "$w" && return 0; done ;;
      tea\ *)
        mapfile -t words < <(_guard_tea_words "$seg")
        if [ "${words[0]:-}" = pr ] || [[ -n "${words[0]:-}" && pulls == "${words[0]}"* ]]; then
          _guard_tea_verdict_word "${words[1]:-}" && return 0
          continue
        fi
        case "${words[0]:-}" in
          api)
            _guard_tea_writes "$seg" || continue
            for w in "${words[@]:1}"; do _guard_reviews_path "$w" && return 0; done ;;
        esac ;;
    esac
  done < <(_guard_segments "$1")
  return 1
}
_GUARD_FORGE_VERDICT_DENY='deny an agent never posts a review verdict (an approval or a request for changes) to a forge - that is a person'"'"'s to give; an agent'"'"'s verdict is recorded with cel solo review <repo>#<pr> <approved|changes> --head <sha> --by <alias> (the PR'"'"'s reviewer runs it). A comment is fine (gh pr review --comment, gh pr comment). A graphql call whose query the guard cannot read counts as a verdict. No CEL_GUARD_ALLOW_ONCE override covers this'

# A GH ALIAS hides what a later command runs: `gh alias set ap "pr review
# --approve"` makes `gh ap 5` an approval the guard cannot see. So no agent
# sets, imports or deletes one, in any role, and no one-off covers it.
_guard_gh_alias_write() { # <command>
  _guard_starts "$1" 'gh alias (set|import|delete|rm)'
}
_GUARD_GH_ALIAS_DENY='deny no agent sets, imports or deletes a gh alias - an alias hides from the guard what a later gh command runs; spell the gh command out. No CEL_GUARD_ALLOW_ONCE override covers this'

# THE HUMAN'S ONE-OFF: `CEL_GUARD_ALLOW_ONCE=1 <command>`, spelled exactly,
# lets that one call skip the rules. Every runtime adapter asks this, through
# guard-classify.sh or directly, so they agree on it. It has to lead a
# command: on a line of its own (`CEL_GUARD_ALLOW_ONCE=1` then a newline) it
# sets a variable and leads nothing. A team member and a reviewer have none
# (nobody stands over their panes to approve one), and it never covers a
# forge review verdict: a person gives that on the forge themselves.
guard_override_honoured() { # <role> <command> -> 0 when the one-off lets the call through
  [[ "$2" =~ ^CEL_GUARD_ALLOW_ONCE=1[[:space:]] ]] || return 1
  if [ "$1" = member ] || [ "${CEL_ROLE:-}" = member ] || [ "${CEL_ROLE:-}" = reviewer ]; then return 1; fi
  local lines first
  lines="$(_guard_lines "$2")"; first="${lines%%$'\n'*}"
  [[ "$first" =~ ^CEL_GUARD_ALLOW_ONCE=1[[:space:]]+[^[:space:]] ]] || return 1
  if _guard_forge_verdict "$2" || _guard_gh_alias_write "$lines"; then return 1; fi
  return 0
}

# THE FORGE TOKEN IS NOBODY'S TO READ: ~/.config/cel/forge holds the API key
# lib/forge.sh sends to Forgejo. Any command naming that directory is refused
# for every role - reading, copying, listing, rewriting alike. A tripwire like
# the rest: a command that reaches it without naming it still runs.
_guard_names_forge_token() { # <command-or-path>
  [[ "$1" =~ cel/forge([^A-Za-z0-9_.-]|$) ]]
}
_GUARD_TOKEN_DENY='deny the forge API token (~/.config/cel/forge) is read by `cel forge` and the land doors only - no agent reads, copies or writes it'

# NOR DOES IT CALL THE CODE BEHIND `cel forge`. lib/forge.sh's functions
# (_forge_fj, _forge_fj_get, forge_pr_*, ...) carry the token to the forge
# themselves, so an agent that sources the file and calls them reaches the
# forge with every guard and authorship check of `cel forge` skipped - a
# close or a PATCH included. Refused: sourcing it (`. .../forge.sh`,
# `source .../forge.sh`, `source <(...forge.sh...)`) anywhere in the line; a
# piece that calls one of its functions, also as a `bash -c` string; an
# `eval` that names one; and a variable assigned one's name (`x=_forge_fj;
# $x ...`). Reading the file is not this. THE LIMIT: these are the spellings
# an agent plausibly writes, matched as text - a script file that sources the
# library, a name built from pieces or decoded at run time still runs. It
# is a tripwire, as the rest of this guard is, not a sandbox.
_guard_forge_lib() { # <command> -> 0 when it sources lib/forge.sh or calls its functions
  local seg re='(^|[^A-Za-z0-9_./-])(\.|source)[[:space:]]+[^[:space:];&|]*forge\.sh([^A-Za-z0-9_.-]|$)'
  [[ "$1" =~ $re ]] && return 0
  re='(^|[^A-Za-z0-9_./-])(\.|source)[[:space:]]+<\(.*forge\.sh'
  [[ "$1" =~ $re ]] && return 0
  re='(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=["'"'"']?_?forge_[A-Za-z0-9_]+'
  [[ "$1" =~ $re ]] && return 0
  re='(^|[^A-Za-z0-9_./-])eval[[:space:]].*(_?forge_[A-Za-z0-9_]+|forge\.sh)'
  [[ "$1" =~ $re ]] && return 0
  while IFS= read -r seg || [ -n "$seg" ]; do
    [[ "$seg" =~ ^(.*[[:space:]]-c[[:space:]]+)?_?forge_[A-Za-z0-9_]+([[:space:]]|$) ]] && return 0
  done < <(_guard_segments "$1")
  return 1
}
_GUARD_FORGE_LIB_DENY='deny lib/forge.sh is cel'"'"'s own code - an agent does not source it or call its _forge_*/forge_* functions (that reaches the forge with every guard and authorship check skipped); use cel forge ... instead (repo, whoami, pr view|checks|reviews|list|create|close|ready, run list|view|logs|rerun)'

# `cel` DECIDES WHO IS ASKING FROM THE CALLER'S ENVIRONMENT - `cel forge` and
# `cel team` by CEL_ROLE, CEL_PRODUCT and the mailbox, `cel inbox` by
# CEL_INBOX_ME/CEL_INBOX_WS, panes by HERDR_* - so a line that runs any `cel`
# command while SETTING a CEL_* or HERDR_* variable - a `VAR=` prefix (empty
# included), `env VAR=`, `export`, `declare` - is a pane dressing up as
# someone else: refused for every role, reads included. Pass --workspace
# <name> instead of CEL_WORKSPACE; `cel inbox send --from` is its own flag.
# CEL_GUARD_ALLOW_ONCE, the human's one-off approval, says nothing about who
# is asking and is not counted. A NAME THAT IS AN EXPANSION counts too, since
# the guard cannot see what it expands to (`X=CEL_TESTING; export $X=1`):
# on a line that runs cel, export/declare/typeset/local/readonly with an
# operand that starts with `$` or a backquote, any nameref (`declare -n`),
# and an assignment to `$X`, `${X}` or `$(...)` (eval, env, printf -v and
# read reach a variable that way) are refused as well. So is SHELL CODE for
# cel's own bash: BASH_ENV=, ENV=, SHELLOPTS=, BASHOPTS=, any BASH_FUNC_
# spelling, and exporting a function (`export -f`, `declare -fx`) - bin/cel
# re-executes itself without them anyway; this names the attempt. Shedding
# variables (unset, env -u, env -i, setsid) is not refused here: cel forge
# and cel team act only for a positively identified agent, and both check the
# identity against its launch's environ (lib/identity.sh cel_launch_identity),
# whose test seam no variable can turn on (cel_under_suite).
_guard_cel_env_tamper() { # <command> -> 0 when it does
  local s="${1//CEL_GUARD_ALLOW_ONCE=/}" re='(^|[^A-Za-z0-9_.-])cel([[:space:]]|$)'
  [[ "$s" =~ $re ]] || return 1
  re='(^|[^A-Za-z0-9_])(CEL|HERDR)_[A-Za-z0-9_]*='
  [[ "$s" =~ $re ]] && return 0
  local decl='(^|[[:space:];&|(])(export|declare|typeset|local|readonly)'
  re="$decl"'[[:space:]][^;&|]*(CEL|HERDR)_'
  [[ "$s" =~ $re ]] && return 0
  _guard_env_name_expansion "$s" && return 0
  # shell code or options for cel's own bash
  re='(^|[^A-Za-z0-9_])(BASH_ENV|ENV|SHELLOPTS|BASHOPTS)='
  [[ "$s" =~ $re ]] && return 0
  [[ "$s" == *BASH_FUNC_* ]] && return 0
  re="$decl"'([[:space:]]+-[-A-Za-z+]*)*[[:space:]]+-[A-Za-z]*f'
  [[ "$s" =~ $re ]]
}
# A VARIABLE WHOSE NAME THE GUARD CANNOT READ: export/declare/typeset/local/
# readonly with an operand that starts with `$` or a backquote, a nameref
# (`declare -n`), an assignment to `$X`, `${X}` or `$(...)` (eval, env,
# printf -v and read reach a variable that way), and printf -v/read/mapfile
# into an expansion.
_guard_env_name_expansion() { # <command> -> 0 when it sets one
  local s="$1" re decl='(^|[[:space:];&|(])(export|declare|typeset|local|readonly)'
  re="$decl"'([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+["'"'"']?(\$|`)'
  [[ "$s" =~ $re ]] && return 0
  re='(^|[[:space:];&|(])(declare|typeset|local)([[:space:]]+-[A-Za-z]*)*[[:space:]]+-[A-Za-z]*n'
  [[ "$s" =~ $re ]] && return 0
  re='\$(\{[^}]*\}|\([^)]*\)|[A-Za-z_][A-Za-z0-9_]*)["'"'"']?='
  [[ "$s" =~ $re ]] && return 0
  re='(^|[[:space:];&|(])(printf[[:space:]]+-v|read|mapfile|readarray)([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+["'"'"']?(\$|`)'
  [[ "$s" =~ $re ]]
}
_GUARD_CEL_ENV_DENY='deny cel reads who is asking from its environment - a line that runs cel while setting, emptying, exporting or declaring a CEL_* or HERDR_* variable, a variable whose name is an expansion ($X, ${X}, $(...)) or a nameref, or shell code for it (BASH_ENV, ENV, SHELLOPTS, BASHOPTS, BASH_FUNC_*, export -f), is refused for every agent; run cel as you are (--workspace <name> picks a workspace, cel inbox send --from names a sender)'

# NOR DOES THE SUITE RUN UNDER A HOOK. Every process beneath a checkout's
# tests/run.sh is trusted with the test seams (lib/common.sh
# cel_under_suite), so a line that runs the suite - `bash tests/run.sh`,
# `./tests/run.sh`, through env, exec, timeout or `cel build-slot --` -
# while setting or exporting BASH_ENV, ENV or PATH, or handing it an
# exported function (a BASH_FUNC_ spelling, `export -f`, `declare -fx`), is
# refused for every agent; tests/run.sh itself also refuses to start with
# BASH_ENV or ENV set. A tripwire like the rest: a script file still runs,
# and agents run as the owner anyway (the limit is spelled out at
# cel_under_suite).
_guard_suite_tamper() { # <command> -> 0 when it does
  local s="$1" re='(^|[^A-Za-z0-9_.-])([^[:space:];&|()]*/)?tests/run\.sh([^A-Za-z0-9_.-]|$)'
  [[ "$s" =~ $re ]] || return 1
  re='(^|[^A-Za-z0-9_])(BASH_ENV|ENV|PATH)='
  [[ "$s" =~ $re ]] && return 0
  [[ "$s" == *BASH_FUNC_* ]] && return 0
  local decl='(^|[[:space:];&|(])(export|declare|typeset|readonly)'
  re="$decl"'[[:space:]]([^;&|]*[[:space:]])?(BASH_ENV|ENV|PATH)([^A-Za-z0-9_]|$)'
  [[ "$s" =~ $re ]] && return 0
  re="$decl"'([[:space:]]+-[-A-Za-z+]*)*[[:space:]]+-[A-Za-z]*f'
  [[ "$s" =~ $re ]]
}
_GUARD_SUITE_TAMPER_DENY='deny the suite trusts every process beneath tests/run.sh with its test seams, so it does not run under a hook - a line that runs tests/run.sh while setting or exporting BASH_ENV, ENV or PATH, or handing it an exported function (BASH_FUNC_*, export -f, declare -fx), is refused for every agent; run the suite from a plain environment (bash tests/run.sh <file>.test.sh)'

# THE GATEWAY CLIENT KEY IS ROTATED BY THE OWNER (`cel gateway rotate-key`,
# lib/gateway-rotate.sh): --stage, --finish and --abort are refused to every
# agent pane, whatever its role; reading the rotation (bare, or --status) is
# open. The verb refuses an agent's process on its own as well - this is the
# earlier, clearer no. Matched anywhere in a piece, not only at its start: a
# wrapper the segmenter does not strip (`env -u CEL_ROLE cel ...`) leaves
# words in front of `cel`, and a false deny here costs a read, nothing more.
_guard_gateway_rotate() { # <command> -> 0 when a piece changes a key rotation
  local seg
  while IFS= read -r seg || [ -n "$seg" ]; do
    [[ "$seg" =~ (^|[\ /])cel\ gateway\ rotate-key( |$) ]] || continue
    [[ "${seg#*gateway rotate-key}" =~ (^|\ )--(stage|finish|abort|force)(=|\ |$) ]] && return 0
  done < <(_guard_segments "$1")
  return 1
}
_GUARD_GATEWAY_ROTATE_DENY='deny rotating the gateway client key (cel gateway rotate-key --stage|--finish|--abort) is the owner'"'"'s action, from the owner'"'"'s own shell - an agent reads it with cel gateway rotate-key --status and asks the owner'

# A TEAM MEMBER'S LAUNCH TOKEN IS NOBODY'S TO READ EITHER: cel team add writes
# <ws>/.cel/teams/<feature>/launch/<alias>.token and `cel run member` spends
# it, both inside one process. An agent that could read or write one could
# start a member past cel team add's admission. Matched on the literal
# spelling AND on every path a command names once resolved against the
# directories it may run in (_guard_walk, _guard_resolve): a member stands in
# its team directory, where `launch/x`, `members/../launch` and a symlink all
# reach the same files.
_guard_names_launch_token() { # <command-or-path> - the literal spelling
  [[ "$1" =~ \.cel/teams/[^/[:space:]]+/launch([^A-Za-z0-9_.-]|$) ]]
}
_guard_launch_path() { # <absolute path> -> 0 when it is a launch dir or in one
  [[ "$1" =~ /\.cel/teams/[^/]+/launch(/|$) ]]
}
_GUARD_LAUNCH_TOKEN_DENY='deny team launch tokens (<ws>/.cel/teams/<feature>/launch/) are written by cel team add and spent by its launcher only - no agent reads, lists or writes them'

# PATHS ARE COMPARED RESOLVED. _guard_norm makes a word absolute against a
# base and folds `.`, `..` and `//` without touching the disk, into _GN. A word
# whose value is not in the text - a variable, a glob, ~user, a substitution -
# has none: rc 1, and callers that need it refuse. _guard_resolve then follows
# existing symlinks (realpath -m), every path in one call.
_guard_norm() { # <base> <word> -> 0 and _GN, or 1
  local base="$1" w="$2" p part
  local -a out=()
  _GN=""
  case "$w" in ''|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*) return 1 ;; esac
  case "$w" in '~') w="$HOME" ;; '~/'*) w="$HOME/${w#'~/'}" ;; '~'*) return 1 ;; esac
  case "$w" in
    /*) p="$w" ;;
    *) [ -n "$base" ] && [ "$base" != '?' ] || return 1; p="$base/$w" ;;
  esac
  local IFS=/
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#out[@]}" -eq 0 ] || out=("${out[@]:0:${#out[@]}-1}") ;;
      *) out+=("$part") ;;
    esac
  done
  _GN="/${out[*]}"
}
_guard_resolve() { # <absolute path...> -> each with symlinks followed, one per line
  [ $# -gt 0 ] || return 0
  realpath -m -- "$@" 2>/dev/null || printf '%s\n' "$@"
}

# EVERY COMMAND IN THE LINE WITH THE DIRECTORIES IT MAY RUN IN: the pane's
# (_GUARD_CWD) and every directory a cd/pushd before it named - from each
# earlier candidate, and the earlier ones kept, since a subshell's cd may have
# ended. `?` is a directory that cannot be told (cd -, cd $X). File-descriptor
# duplications (2>&1, &>) are folded first so their `&` does not split a
# command. Sets _GW_SEG[i] and _GW_DIRS[i] (tab-separated).
_guard_walk() { # <command>
  local seg w d joined="${_GUARD_CWD:-$PWD}"
  local -a dirs=("${_GUARD_CWD:-$PWD}") t nds
  _GW_SEG=(); _GW_DIRS=()
  while IFS= read -r seg || [ -n "$seg" ]; do
    [ -n "$seg" ] || continue
    _GW_SEG+=("$seg")
    _GW_DIRS+=("$joined")
    case "$seg" in
      cd|"cd "*|pushd|"pushd "*|popd|"popd "*)
        read -r -a t <<< "$seg"
        w="${t[1]:-~}"; case "$w" in -[LPe@]) w="${t[2]:-~}" ;; esac
        [ "${t[0]}" != popd ] || w=-
        nds=()
        for d in "${dirs[@]}"; do
          if [ "$w" != - ] && _guard_norm "$d" "$w"; then nds+=("$_GN"); else nds+=('?'); fi
        done
        dirs+=("${nds[@]}")
        printf -v joined '%s\t' "${dirs[@]}"; joined="${joined%$'\t'}" ;;
    esac
  done < <(_guard_segments "$(printf '%s' "$1" | sed -E 's/[0-9]*>&[0-9-]+/ /g; s/\|&/|/g; s/&>/>/g')")
}

# Does any word of the command, resolved, name a launch directory?
_guard_cmd_reaches_launch() { # <command> -> 0 when it does
  _guard_names_launch_token "$1" && return 0
  local i w c d r k
  local -a t ds cands abs=()
  local -A seen=()
  local -; set -f   # split words below without globbing them
  _guard_walk "$1"
  for i in "${!_GW_SEG[@]}"; do
    if [[ "${_GW_DIRS[i]}" == *$'\t'* ]]; then IFS=$'\t' read -r -a ds <<< "${_GW_DIRS[i]}"; else ds=("${_GW_DIRS[i]}"); fi
    # shellcheck disable=SC2206 # word splitting is the point; globbing is off
    t=(${_GW_SEG[i]})
    for w in "${t[@]}"; do
      cands=("$w")
      [[ "$w" != *=* ]] || cands+=("${w#*=}")
      [[ "$w" != *[\<\>]* ]] || cands+=("${w##*[<>]}")
      for c in "${cands[@]}"; do
        [ -n "$c" ] && [[ "$c" != -* ]] || continue
        for d in "${ds[@]}"; do
          k="$d"$'\t'"$c"; [ -z "${seen[$k]+x}" ] || continue; seen[$k]=1
          _guard_norm "$d" "$c" && abs+=("$_GN")
        done
      done
    done
  done
  [ "${#abs[@]}" -gt 0 ] || return 1
  for r in "${abs[@]}"; do _guard_launch_path "$r" && return 0; done
  while IFS= read -r r; do _guard_launch_path "$r" && return 0; done < <(_guard_resolve "${abs[@]}")
  return 1
}
_guard_path_reaches_launch() { # <file path> -> 0 when it is in a launch dir
  _guard_names_launch_token "$1" && return 0
  _guard_norm "${_GUARD_CWD:-$PWD}" "$1" || return 1
  _guard_launch_path "$_GN" || _guard_launch_path "$(_guard_resolve "$_GN")"
}

# A GIT WRITE anywhere in the line. `git -C <dir> commit`, `git --git-dir=x
# push`, `git -c k=v merge`: the verb is no longer adjacent to `git`, so those
# options are stripped before matching. Callers that care WHERE the write
# lands look at the original command, since -C is exactly how a command
# reaches into another checkout.
_guard_git_writes() { # <command> -> 0 when it writes to a git repository
  local norm="$1" re='git( +-C +[^ ]+| +--git-dir=[^ ]+| +--work-tree=[^ ]+| +-c +[^ ]+)+'
  while [[ "$norm" =~ $re ]]; do norm="${norm/"${BASH_REMATCH[0]}"/git}"; done
  case "$norm" in
    *git\ commit*|*git\ push*|*git\ merge*|*git\ rebase*|*git\ reset*|*git\ revert*|\
    *git\ cherry-pick*|*git\ am\ *|*git\ apply*|*git\ stash*|*git\ checkout*|*git\ switch*|\
    *git\ restore*|*git\ add\ *|*git\ rm\ *|*git\ mv\ *|*git\ tag\ *|*git\ worktree\ *|\
    *git\ branch\ -[dDmM]*|*git\ branch\ --delete*|*git\ branch\ --move*|*git\ clean*) return 0;;
  esac
  return 1
}

# A SOLO AGENT IS THE BUILDER: it edits, commits, pushes, opens PRs, makes its
# own git worktrees and runs its own subagents. What it does NOT do is start
# other Celestial agents or panes (a reviewer for its own PR excepted), review
# its own PR, or merge by hand: the solo merge door is `cel solo land`, which
# checks review of the exact head and CI.
_guard_solo() { # <command> -> allow | deny <reason>
  if _guard_starts "$1" 'cel run (orchestrator|root|console|core|solo)' 'cel (core|console)' 'herdr agent start' 'herdr worktree (create|open)'; then
    printf 'deny a solo agent starts no other Celestial agents or panes (only `cel run reviewer` for its own PR)'
    return 0
  fi
  if _guard_starts "$1" 'cel solo review'; then
    printf 'deny a solo agent does not review its own PR - its reviewer records the verdict'
    return 0
  fi
  if _guard_starts "$1" 'gh pr merge' 'gh api .*pulls/[0-9]+/merge' 'tea (pr|pulls|pull) (merge|m)' 'curl .*/pulls/[0-9]+/merge[^ ]*'; then
    printf 'deny a solo agent merges through `cel solo land <repo>#<pr>`, which checks policy, review of the exact head and CI before it merges'
    return 0
  fi
  # Nor does it change its forge by hand at all - close, delete, branch
  # protection, merge: `cel forge` opens PRs and `cel solo land` merges them.
  if _guard_forge_raw_write "$1"; then
    printf 'deny a solo agent changes its forge only through `cel forge` and `cel solo land`, never curl at its API or tea'
    return 0
  fi
  printf allow
}

# CORE COORDINATES; IT DOES NOT BUILD. It is orchestrator-class (every
# repository and GitHub write an orchestrator is refused, it is refused too),
# and on top of that the verbs that belong to a PRODUCT's agent are refused
# here, before guard_classify's blanket allow of `cel`: landing and review
# verdicts, starting reviewers, and the box's own configuration and release
# (`cel mode` is core's one config write, and it is a `cel` command, so it
# passes).
_guard_core() { # <command> -> deny <reason>, or nothing
  if _guard_starts "$1" 'cel solo (land|review)' 'cel spike'; then
    printf 'deny core coordinates; the product'"'"'s own agent builds, reviews and lands - ask it: cel inbox send <product>-orch "<what you want>" --workspace <w>'
    return 0
  fi
  if _guard_starts "$1" 'cel forge pr (close|ready)' 'cel forge run rerun'; then
    printf 'deny core closes, readies and reruns nothing on a forge; the product'"'"'s own agent does - ask it: cel inbox send <product>-orch "<what you want>" --workspace <w>'
    return 0
  fi
  if _guard_starts "$1" 'cel run (reviewer|root)' 'herdr agent start' 'herdr worktree (create|open|remove)'; then
    printf 'deny core starts product agents only (cel run orchestrator --product <p> --workspace <w>, add --restart to relaunch one); reviewers are the product agent'"'"'s'
    return 0
  fi
  if _guard_starts "$1" 'cel (learn|release|promote|update|setup)'; then
    printf 'deny core'"'"'s only configuration write is cel mode; box configuration, learnings and releases are the owner'"'"'s (or the celestial product agent'"'"'s)'
    return 0
  fi
}

# Shell writes to files under repos/ - the spellings an agent uses.
_guard_shell_edits_repos() { # <command> -> 0 when it edits under repos/
  case "$1" in
    *sed\ -i*repos/*|*perl\ -pi*repos/*|*\>\ *repos/*|*\>\>\ *repos/*|*tee\ *repos/*|\
    *rm\ *repos/*|*mv\ *repos/*|*cp\ *repos/*|*touch\ *repos/*|*mkdir\ *repos/*|*chmod\ *repos/*|\
    *truncate\ *repos/*|*install\ *repos/*|*rsync\ *repos/*|*ln\ *repos/*) return 0;;
  esac
  return 1
}

# ── team members (CEL_ROLE=member; lib/run.sh `cel run member`) ─────────────
# A member is scoped by its launch: CEL_TEAM (the feature), CEL_TEAM_ROLE,
# CEL_TEAM_MEMBER (its alias), CEL_WORKSPACE and, for a builder,
# CEL_TEAM_BRANCH. Without a whole scope everything is refused.
#
# A BUILDER writes its own worktree (<team>/wt/<alias>) and nothing else - a
# shell write may also go to /tmp - commits there, and pushes ONLY
# `git push origin <its branch>` (or HEAD:<its branch>). It opens no PR and
# lands nothing: the lead integrates. Every OTHER role reads repositories and
# writes only <team>/artifacts/<role>/ and <team>/notes/<alias>/ (a product
# member also brief.md and acceptance.yaml); team.json, events, verdicts,
# packets, contracts and launch/ change only through `cel team` verbs.
# No member merges, lands, starts or stops an agent or pane, reads a token or
# writes to a forge by hand, and git runs only from a list of known verbs: an
# unknown one may be an alias for anything.
_GUARD_TEAM_READONLY_ROLES=' product design qa platform release analyst '
_GUARD_MEMBER_NO_SCOPE='deny a team member without a whole launch scope (CEL_TEAM, CEL_TEAM_ROLE, CEL_TEAM_MEMBER, CEL_WORKSPACE, and a builder'"'"'s CEL_TEAM_BRANCH) has no scope - ask the lead to retire it and add it again (cel team add)'

_guard_member_scope() { # -> 0 and _GM_* set, or 1
  _GM_TEAM="${CEL_TEAM:-}" _GM_ROLE="${CEL_TEAM_ROLE:-}" _GM_ME="${CEL_TEAM_MEMBER:-}" _GM_BRANCH="${CEL_TEAM_BRANCH:-}"
  [[ "$_GM_TEAM" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] && [[ "$_GM_ME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    && [[ "${CEL_WORKSPACE:-}" == /* ]] || return 1
  if [ "$_GM_ROLE" = builder ]; then
    [[ "$_GM_BRANCH" =~ ^team/"$_GM_TEAM"/[A-Za-z0-9._-]+$ ]] || return 1
  else
    [[ "$_GUARD_TEAM_READONLY_ROLES" == *" $_GM_ROLE "* ]] || return 1
  fi
  local -a r
  mapfile -t r < <(_guard_resolve "$CEL_WORKSPACE/.cel/teams/$_GM_TEAM" "$CEL_WORKSPACE/.cel/teams/$_GM_TEAM/wt/$_GM_ME" "$CEL_WORKSPACE")
  _GM_TDIR="${r[0]:-}" _GM_WT="${r[1]:-}" _GM_WS="${r[2]:-}"
  [ -n "$_GM_TDIR" ] && [ -n "$_GM_WT" ] && [ -n "$_GM_WS" ]
}

# gh api with a write: a non-GET method or a request body.
_guard_gh_api_writes() { # <command>
  local seg w method="" i n
  while IFS= read -r seg || [ -n "$seg" ]; do
    case "$seg" in "gh api"|"gh api "*) ;; *) continue ;; esac
    local -a t; read -r -a t <<< "$seg"; n=${#t[@]}
    for ((i = 2; i < n; i++)); do
      w="${t[i]}"
      case "$w" in
        -X|--method) method="${t[i+1]:-}" ;;
        --method=*) method="${w#--method=}" ;;
        -X?*) method="${w#-X}" ;;
        -f|-F|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*|-f?*|-F?*) return 0 ;;
      esac
    done
    case "${method^^}" in ""|GET) ;; *) return 0 ;; esac
  done < <(_guard_segments "$1")
  return 1
}

# May this member write this (absolute, resolved) path? <how>: tool for the
# native edit tools, bash for a shell write.
_guard_member_may_write() { # <path> <tool|bash>
  local p="$1"
  if [ "$2" = bash ]; then
    case "$p" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) return 0 ;; esac
  fi
  if [ "$_GM_ROLE" = builder ]; then
    case "$p" in
      "$_GM_WT/.git"|"$_GM_WT/.git/"*) return 1 ;;
      "$_GM_WT"|"$_GM_WT/"*) return 0 ;;
    esac
    # Scratch, but never the workspace - which may itself sit under /tmp.
    if [ "$2" = bash ]; then
      case "$p" in "$_GM_WS"|"$_GM_WS/"*) return 1 ;; /tmp/*|"${TMPDIR:-/tmp}"/*) return 0 ;; esac
    fi
    return 1
  fi
  case "$p" in
    "$_GM_TDIR/artifacts/$_GM_ROLE"|"$_GM_TDIR/artifacts/$_GM_ROLE/"*) return 0 ;;
    "$_GM_TDIR/notes/$_GM_ME"|"$_GM_TDIR/notes/$_GM_ME/"*) return 0 ;;
  esac
  if [ "$_GM_ROLE" = product ]; then
    case "$p" in "$_GM_TDIR/brief.md"|"$_GM_TDIR/acceptance.yaml") return 0 ;; esac
  fi
  return 1
}
_guard_member_where() { # -> where this member may write, for a refusal
  if [ "$_GM_ROLE" = builder ]; then
    printf 'a builder writes only in its own worktree, %s (a shell write also /tmp)' "$_GM_WT"
  else
    printf 'a %s team member writes only under %s/artifacts/%s/ and %s/notes/%s/%s - team.json, events, verdicts, packets, contracts and launch/ change only through cel team verbs' \
      "$_GM_ROLE" "$_GM_TDIR" "$_GM_ROLE" "$_GM_TDIR" "$_GM_ME" "$([ "$_GM_ROLE" != product ] || printf ' (and brief.md, acceptance.yaml)')"
  fi
}

# WHAT A SHELL COMMAND WRITES: its redirection targets and the file
# arguments of the commands that write files. `?` = it writes, but where
# cannot be told from the text (wget without -O, patch, tar x, unzip).
# Interpreters (python -c, node -e, a script) are not parsed: a tripwire.
_guard_seg_targets() { # <segment> -> one word per line
  local -a t a=() args pos
  read -r -a t <<< "$1"
  local i n=${#t[@]} w pre post cmd tgt inplace script
  for ((i = 0; i < n; i++)); do
    w="${t[i]}"
    if [[ "$w" == *'>'* ]]; then
      pre="${w%%>*}"; post="${w#*>}"; post="${post#>}"; post="${post#|}"
      [[ "$pre" =~ ^[0-9]*$ ]] || a+=("$pre")
      if [ -z "$post" ]; then i=$((i + 1)); post="${t[i]:-?}"; fi
      printf '%s\n' "$post"
    elif [[ "$w" == *'<'* ]]; then
      pre="${w%%<*}"; [ -z "$pre" ] || a+=("$pre")
      [ -n "${w##*<}" ] || i=$((i + 1))
    else
      a+=("$w")
    fi
  done
  [ "${#a[@]}" -gt 0 ] || return 0
  cmd="${a[0]##*/}"; args=("${a[@]:1}"); pos=(); n=${#args[@]}
  case "$cmd" in
    tee)
      for w in "${args[@]}"; do [[ "$w" == -* ]] || printf '%s\n' "$w"; done ;;
    cp|mv|install|ln|rsync)
      tgt=""
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -t|--target-directory) tgt="${args[i+1]:-?}"; i=$((i + 1)) ;;
          --target-directory=*) tgt="${w#*=}" ;;
          -S|--suffix|-m|--mode|-o|--owner|-g|--group) i=$((i + 1)) ;;
          -*) ;;
          *) pos+=("$w") ;;
        esac
      done
      if [ -n "$tgt" ]; then printf '%s\n' "$tgt"
      elif [ "${#pos[@]}" -ge 2 ]; then printf '%s\n' "${pos[${#pos[@]}-1]}"
      else printf '?\n'; fi ;;
    rm|rmdir|touch|mkdir|truncate|unlink|shred)
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -s|--size|-m|--mode|-r|--reference|-n|--iterations) i=$((i + 1)) ;;
          -*) ;;
          *) printf '%s\n' "$w" ;;
        esac
      done ;;
    chmod|chown|chgrp)
      for w in "${args[@]}"; do [[ "$w" == -* ]] || pos+=("$w"); done
      [[ " ${args[*]} " == *" --reference="* ]] || pos=("${pos[@]:1}")
      [ "${#pos[@]}" -eq 0 ] || printf '%s\n' "${pos[@]}" ;;
    sed|perl)
      inplace=0 script=0
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          --in-place*) inplace=1 ;;
          -e|--expression|-f|--file) script=1; i=$((i + 1)) ;;
          --*) ;;
          -*)
            [[ "$w" != -*i* ]] || inplace=1
            if [ "$cmd" = perl ] && [[ "$w" == -*e ]]; then script=1; i=$((i + 1)); fi ;;
          *) pos+=("$w") ;;
        esac
      done
      if [ "$inplace" = 1 ]; then
        [ "$script" = 1 ] || pos=("${pos[@]:1}")
        if [ "${#pos[@]}" -gt 0 ]; then printf '%s\n' "${pos[@]}"; else printf '?\n'; fi
      fi ;;
    dd)
      for w in "${args[@]}"; do case "$w" in of=*) printf '%s\n' "${w#of=}" ;; esac; done ;;
    curl)
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -o|--output) printf '%s\n' "${args[i+1]:-?}"; i=$((i + 1)) ;;
          --output=*) printf '%s\n' "${w#*=}" ;;
          -O|--remote-name|--remote-name-all) printf '?\n' ;;
        esac
      done ;;
    wget)
      tgt='?'
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -O|--output-document) tgt="${args[i+1]:-?}"; i=$((i + 1)) ;;
          --output-document=*) tgt="${w#*=}" ;;
          -*O-) tgt=- ;;
          -*O?*) tgt="${w#*O}" ;;
        esac
      done
      [ "$tgt" = - ] || printf '%s\n' "$tgt" ;;
    patch|unzip) printf '?\n' ;;
    tar) if [[ " ${args[*]} " =~ \ (-?[A-Za-z]*x[A-Za-z]*|--extract|--get)\  ]]; then printf '?\n'; fi ;;
  esac
  return 0
}

# Every write target of the walked command, against every directory it may
# run in, must be one this member may write.
_guard_member_targets() { # (after _guard_walk) -> deny <reason>, or nothing
  local i t d k r
  local -a ds abs=() src=() res
  for i in "${!_GW_SEG[@]}"; do
    IFS=$'\t' read -r -a ds <<< "${_GW_DIRS[i]}"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ "$t" = '?' ]; then
        printf 'deny %s - and where `%s` writes cannot be told' "$(_guard_member_where)" "${_GW_SEG[i]}"; return 0
      fi
      for d in "${ds[@]}"; do
        _guard_norm "$d" "$t" || { printf 'deny %s - and where %s is (in `%s`) cannot be told' "$(_guard_member_where)" "$t" "${_GW_SEG[i]}"; return 0; }
        abs+=("$_GN"); src+=("$t")
      done
    done < <(_guard_seg_targets "${_GW_SEG[i]}")
  done
  [ "${#abs[@]}" -gt 0 ] || return 0
  mapfile -t res < <(_guard_resolve "${abs[@]}")
  for k in "${!abs[@]}"; do
    for r in "${res[k]:-${abs[k]}}"; do
      _guard_member_may_write "$r" bash \
        || { printf 'deny %s - not %s' "$(_guard_member_where)" "${src[k]}"; return 0; }
    done
  done
}

# git for a member: a known verb, known global options only, and for a
# builder a write only inside its own worktree.
_GUARD_GIT_READ=' status log diff show fetch rev-parse rev-list ls-files ls-tree ls-remote cat-file blame annotate grep describe shortlog merge-base name-rev show-ref for-each-ref version help count-objects check-ignore check-attr cherry range-diff whatchanged var diff-tree diff-files diff-index '
_GUARD_GIT_BUILD=' add commit restore rm mv checkout switch reset rebase merge cherry-pick revert apply am clean pull '
_guard_member_git() { # <segment> <dirs, tab-separated> -> deny <reason>, or nothing
  local seg="$1" w kv verb="" kind="" cdir="" i n d listing key builder=0
  local -a t args pos=() ds locs=() res
  [ "$_GM_ROLE" != builder ] || builder=1
  read -r -a t <<< "$seg"; n=${#t[@]}; i=1
  while [ "$i" -lt "$n" ]; do
    w="${t[i]}"
    case "$w" in
      -C) cdir="${t[i+1]:-}"; [ -n "$cdir" ] || { printf 'deny git -C names no directory'; return 0; }; i=$((i + 2)) ;;
      -c)
        kv="${t[i+1]:-}"
        if [ "$builder" = 1 ] && [[ "$kv" =~ ^(user\.(name|email)|commit\.gpgsign)= ]]; then i=$((i + 2))
        else printf 'deny a team member sets no git config on the command line (git -c %s): one can redirect a push or run a command' "${kv%%=*}"; return 0; fi ;;
      --no-pager|-P|-p|--paginate|--no-optional-locks|--literal-pathspecs|--no-replace-objects) i=$((i + 1)) ;;
      --version|--help|-h) return 0 ;;
      -*) printf 'deny git %s is not a git option a team member uses (no --git-dir, --work-tree, --exec-path or other global options)' "$w"; return 0 ;;
      *) verb="$w"; i=$((i + 1)); break ;;
    esac
  done
  [ -n "$verb" ] || return 0
  args=("${t[@]:i}")
  for w in "${args[@]}"; do
    case "$w" in
      --upload-pack*|--receive-pack*|--exec|--exec=*|--output|--output=*|--open-files-in-pager*|-O|-O?*|--ext-diff|--textconv)
        printf 'deny git %s %s: a team member runs no git option that writes a file or runs a command' "$verb" "$w"; return 0 ;;
    esac
    [[ "$w" == -* ]] || pos+=("$w")
  done
  case "$_GUARD_GIT_READ" in *" $verb "*) kind=read ;; esac
  if [ -z "$kind" ]; then
    case "$_GUARD_GIT_BUILD" in *" $verb "*) kind=write ;; esac
  fi
  if [ -z "$kind" ]; then
    case "$verb" in
      branch|tag)
        kind=read listing=0
        for w in "${args[@]}"; do
          case "$verb:$w" in
            *:-d|*:-f|*:--delete|*:--force|*:--create-reflog) kind=write ;;
            branch:-D|branch:-m|branch:-M|branch:-c|branch:-C|branch:-u|branch:-t|branch:--move|branch:--copy|branch:--set-upstream-to*|branch:--unset-upstream|branch:--edit-description|branch:--track*) kind=write ;;
            tag:-a|tag:-s|tag:-u|tag:-m|tag:-F|tag:--annotate|tag:--sign) kind=write ;;
            *:-l|*:--list|*:--contains*|*:--no-contains*|*:--merged*|*:--no-merged*|*:--points-at*) listing=1 ;;
          esac
        done
        [ "${#pos[@]}" -eq 0 ] || [ "$listing" = 1 ] || kind=write ;;
      remote)
        if [ "${#pos[@]}" -eq 0 ] || [ "${pos[0]}" = show ] || [ "${pos[0]}" = get-url ]; then kind=read
        else printf 'deny a team member never changes a git remote (git remote %s)' "${pos[0]}"; return 0; fi ;;
      stash) case "${pos[0]:-push}" in list|show) kind=read ;; *) kind=write ;; esac ;;
      reflog) case "${pos[0]:-show}" in show|exists) kind=read ;; *) kind=write ;; esac ;;
      worktree)
        [ "${pos[0]:-}" = list ] || { printf 'deny a team member makes no git worktree (git worktree %s): cel run member made its own' "${pos[0]:-}"; return 0; }
        kind=read ;;
      symbolic-ref)
        [ "${#pos[@]}" -le 1 ] || { printf 'deny a team member moves no symbolic ref'; return 0; }
        kind=read ;;
      config)
        if [[ " ${args[*]} " =~ \ (--get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--show-origin|--show-scope|--name-only)\  ]] \
           || [ "${pos[0]:-}" = get ] || [ "${pos[0]:-}" = list ]; then
          kind=read
        else
          key="${pos[0]:-}"; [ "$key" != set ] || key="${pos[1]:-}"
          if [ "$builder" = 1 ] && [[ "$key" =~ ^user\.(name|email)$ ]] \
             && ! [[ " ${args[*]} " =~ \ (--global|--system|--file|-f|--blob|--worktree|--unset|--unset-all|--rename-section|--remove-section|--add|--replace-all)\  ]]; then
            kind=write
          else
            printf 'deny a team member changes no git config but a builder'"'"'s own user.name/user.email (git config %s): remote, push, alias and url settings redirect a push' "${key:-?}"; return 0
          fi
        fi ;;
      push) kind=push ;;
      *) printf 'deny git %s is not a git verb a team member may run - an unknown verb may be an alias for anything' "$verb"; return 0 ;;
    esac
  fi
  [ "$kind" != read ] || return 0
  [ "$builder" = 1 ] || { printf 'deny a %s team member reads repositories and never writes one (git %s) - a builder does' "$_GM_ROLE" "$verb"; return 0; }
  # Where: every directory the command may run in (and -C from it).
  IFS=$'\t' read -r -a ds <<< "$2"
  for d in "${ds[@]}"; do
    if [ -n "$cdir" ]; then
      _guard_norm "$d" "$cdir" || { printf 'deny %s - and which checkout git -C %s names cannot be told' "$(_guard_member_where)" "$cdir"; return 0; }
      locs+=("$_GN")
    else
      [ "$d" != '?' ] || { printf 'deny %s - and which checkout this git runs in cannot be told (after cd)' "$(_guard_member_where)"; return 0; }
      locs+=("$d")
    fi
  done
  mapfile -t res < <(_guard_resolve "${locs[@]}")
  for d in "${res[@]}"; do
    case "$d" in
      "$_GM_WT/.git"|"$_GM_WT/.git/"*) printf 'deny %s - not its .git' "$(_guard_member_where)"; return 0 ;;
      "$_GM_WT"|"$_GM_WT/"*) ;;
      *) printf 'deny %s - git %s would run in %s' "$(_guard_member_where)" "$verb" "$d"; return 0 ;;
    esac
  done
  [ "$kind" != push ] || _guard_builder_push "${args[@]}"
}

# A BUILDER'S PUSH, the one shape: `git push [options] origin <refspec>...`,
# every refspec its own branch (B, B:B, HEAD:B, refs/heads/B). The remote is
# literally `origin`; a push with no refspec follows config and is refused.
_guard_builder_push() { # <push arguments...> -> deny <reason>, or nothing
  local b="$_GM_BRANCH" w r src dst remote="" n=0
  local why="a builder pushes only its own branch: git push origin $b (or HEAD:$b)"
  for w in "$@"; do
    case "$w" in
      -u|--set-upstream|-f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes|-q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--atomic|--porcelain|--progress|--no-progress) ;;
      -*) [[ "$w" =~ ^-[ufqvn]+$ ]] || { printf 'deny %s - not %s' "$why" "$w"; return 0; } ;;
      *)
        if [ -z "$remote" ]; then
          remote="$w"
          [ "$remote" = origin ] || { printf 'deny %s - the remote is origin, not %s' "$why" "$w"; return 0; }
        else
          n=$((n + 1)); r="${w#+}"
          if [[ "$r" == *:* ]]; then src="${r%%:*}"; dst="${r#*:}"; else src="$r"; dst="$r"; fi
          case "$src" in HEAD|"$b"|"refs/heads/$b") ;; *) printf 'deny %s - not from %s' "$why" "${src:-nothing (a delete)}"; return 0 ;; esac
          case "$dst" in "$b"|"refs/heads/$b") ;; *) printf 'deny %s - not to %s' "$why" "$dst"; return 0 ;; esac
        fi ;;
    esac
  done
  [ -n "$remote" ] && [ "$n" -gt 0 ] \
    || printf 'deny %s - name the remote and the branch: a push without a refspec follows config' "$why"
}

_guard_member() { # <command> -> allow | deny <reason>
  local cmd="$1" i seg d
  _guard_member_scope || { printf '%s' "$_GUARD_MEMBER_NO_SCOPE"; return 0; }
  # Every member, whatever its role. (Rex controls: _guard_rex_writes, in
  # guard_classify, for members and reviewers alike.)
  if _guard_starts "$cmd" 'cel run' 'cel (core|console)' 'cel ws (up|down|reset)' 'cel team (start|add|retire|close|cap)' \
       'herdr agent (start|stop)' 'herdr worktree' 'herdr pane (close|split|send-text|send-keys|run)' 'herdr (tab|workspace) (create|close)'; then
    printf 'deny a team member starts and stops no agents or panes and runs no lead verb - ask the lead (cel team event %s <type> --to <lead>)' "$_GM_TEAM"
    return 0
  fi
  if _guard_starts "$cmd" 'cel (solo|here) (land|review)' 'cel afk' 'gh pr merge' 'gh api .*pulls/[0-9]+/merge' \
       'tea (pr|pulls|pull) (merge|m)' 'curl .*/pulls/[0-9]+/merge[^ ]*'; then
    printf 'deny a team member never merges, lands or records a PR verdict - the lead integrates and lands (cel solo land); report with cel team event|verdict %s' "$_GM_TEAM"
    return 0
  fi
  if _guard_forge_raw_write "$cmd" || _guard_gh_api_writes "$cmd" \
     || _guard_starts "$cmd" 'cel forge pr (create|close|ready)' 'cel forge run rerun' 'gh pr (create|merge|close|ready|reopen|edit|review|comment)' \
          'gh issue (create|close|reopen|edit|comment|delete|transfer|lock|unlock|pin|unpin)' \
          'gh release (create|delete|edit|upload)' 'gh repo (create|delete|edit|fork|rename|archive|unarchive|sync)' \
          'gh run (rerun|cancel|delete)' 'gh workflow (run|enable|disable)'; then
    printf 'deny a team member writes to no forge - no PR, comment, review or API write; the lead opens and lands the integration PR, and members report with cel team event|verdict %s' "$_GM_TEAM"
    return 0
  fi
  # git reads its environment before its options: GIT_DIR, GIT_CONFIG_* and
  # the like would move a push or define an alias out of sight.
  if [[ "$cmd" =~ (^|[^A-Za-z0-9_])GIT_[A-Z0-9_]+= ]]; then
    printf 'deny a team member sets no GIT_* environment: it could point git at another repository or config'
    return 0
  fi
  _guard_walk "$cmd"
  for i in "${!_GW_SEG[@]}"; do
    seg="${_GW_SEG[i]}"
    case "$seg" in
      git|"git "*)
        d="$(_guard_member_git "$seg" "${_GW_DIRS[i]}")"
        [ -z "$d" ] || { printf '%s' "$d"; return 0; } ;;
    esac
    # Read-only roles: the cel verbs a member reports and previews with.
    [ "$_GM_ROLE" != builder ] || continue
    case "$seg" in cel|cel\ *) ;; *) continue ;; esac
    [[ "$seg" =~ ^cel\ (serve|inbox|budget|fleet|version|services|help)(\ |$) \
    || "$seg" =~ ^cel\ team\ (event|verdict|ack|status)(\ |$) \
    || "$seg" =~ ^cel\ forge\ (repo|whoami)(\ |$) \
    || "$seg" =~ ^cel\ forge\ pr\ (view|checks|reviews|list)(\ |$) \
    || "$seg" =~ ^cel\ forge\ run\ (list|view|logs)(\ |$) \
    || "$seg" =~ ^cel\ decide\ (ask|list)(\ |$) \
    || "$seg" =~ ^cel\ learn\ list(\ |$) ]] && continue
    printf 'deny a %s team member runs only cel serve, inbox, budget, fleet, forge reads, decide ask|list and cel team event|verdict|ack|status - not: %s' "$_GM_ROLE" "$seg"
    return 0
  done
  d="$(_guard_member_targets)"
  [ -z "$d" ] || { printf '%s' "$d"; return 0; }
  printf allow
}

# The native edit tools for a member: the same places a shell write may go,
# minus /tmp for a builder. A relative path is the pane's (_GUARD_CWD).
_guard_member_path() { # <file_path> -> allow | deny <reason>
  local p="$1" r
  _guard_member_scope || { printf '%s' "$_GUARD_MEMBER_NO_SCOPE"; return 0; }
  _guard_norm "${_GUARD_CWD:-$PWD}" "$p" || { printf 'deny %s - and where %s is cannot be told' "$(_guard_member_where)" "$p"; return 0; }
  for r in "$(_guard_resolve "$_GN")"; do
    _guard_member_may_write "$r" tool || { printf 'deny %s - not %s' "$(_guard_member_where)" "$p"; return 0; }
  done
  printf allow
}

# A REX COMMAND THAT IS NOT A READ. Team members and reviewers are windows in
# their product agent's Rex session (lib/rex.sh), so a Rex control that opens,
# closes, moves or types into a terminal would reach the lead's own window.
# The argv is parsed, not prefix-matched: global flags (-S/--server,
# -C/--client, --timeout, --color with a value; --autostart[=..], -v) are
# skipped wherever they stand before the verb, and the verb path must be one
# of the reads - ls/list, session|window|block ls|list|inspect, capture,
# `block call process`, actions, api list|describe, version, whoami, help.
# Everything else, an unknown flag before the verb and `rex api call` and
# `rex do` (which cannot be told apart from writes) included, is a write.
_guard_rex_writes() { # <command> -> 0 when a piece runs a non-read rex command
  local seg i n w verb sub pos
  local -a a
  while IFS= read -r seg || [ -n "$seg" ]; do
    read -ra a <<< "$seg"
    [ "${#a[@]}" -gt 0 ] && [ "${a[0]##*/}" = rex ] || continue
    n="${#a[@]}"; i=1
    while [ "$i" -lt "$n" ]; do
      case "${a[$i]}" in
        -S|--server|-C|--client|--timeout|--color) i=$((i + 2)) ;;
        --server=*|--client=*|--timeout=*|--color=*|--autostart|--autostart=*|-v|-vv|-vvv|--verbose) i=$((i + 1)) ;;
        -h|--help) continue 2 ;;
        -*) return 0 ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    verb="${a[$i]}"; sub="${a[$((i + 1))]:-}"
    case "$verb" in
      ls|list|capture|actions|version|whoami|help) continue ;;
      session|window|block)
        case "$sub" in ls|list|inspect) continue ;; esac
        if [ "$verb $sub" = 'block call' ]; then
          # the method is the first positional after `call`
          pos=""; i=$((i + 2))
          while [ "$i" -lt "$n" ]; do
            w="${a[$i]}"
            case "$w" in
              -s|--session|-w|--window|-b|--block|-S|--server|-C|--client|--timeout|--color) i=$((i + 2)) ;;
              -*) i=$((i + 1)) ;;
              *) pos="$w"; break ;;
            esac
          done
          [ "$pos" != process ] || continue
        fi
        return 0 ;;
      api) case "$sub" in list|ls|describe) continue ;; esac; return 0 ;;
      *) return 0 ;;
    esac
  done < <(_guard_segments "$1")
  return 1
}

# ── reviewers (CEL_ROLE=reviewer; lib/run.sh `cel run reviewer`) ──────────────
# A REVIEWER JUDGES; IT CHANGES NOTHING IT JUDGES. Every CEL_ROLE=reviewer -
# the plain reviewer, an extra one (--focus) and a QA agent (--qa) alike -
# reads, records its own verdict (cel solo review binds --by to its own
# mailbox), mails (cel inbox), comments (gh pr comment, gh pr review
# --comment) and runs the change (cel preview, cel serve, a browser). Its
# product's agent does everything else. So git, cel and gh are ALLOWLISTS for
# it, judged per piece that runs them (a review message that mentions `git
# push` is mail); herdr's writes and any forge write by hand are refused.

# git: every global option stripped, then a read verb. Refused outright: the
# global options that run commands (-c, --config-env, --exec-path, and
# -p/--paginate, which runs the pager) and those that point git at another
# repository, whose config could run programs (--git-dir, --work-tree,
# --namespace, and -C to anywhere but the reviewer's own checkout,
# CEL_REVIEW_CHECKOUT from its launch, spelled as an absolute or ~ path).
# `fetch` only into remote-tracking refs: no refspec with a colon or a +, no
# --force, no --recurse-submodules (git in each submodule, with its config).
# A reviewer needs no checkout of its own: cel run reviewer makes its
# detached checkout before it starts.
#
# A READ VERB'S FLAGS CAN STILL WRITE OR RUN, so these are refused on every
# verb (from each verb's `git <verb> -h` and man page):
#   --output=<file>            diff/log/show/range-diff write the diff to a file
#   --ext-diff                 runs the external diff program
#   --textconv                 runs a textconv filter (diff, log, show, blame,
#                              grep, cat-file; diff/log/show's default stays)
#   --filters                  cat-file runs the clean/smudge filters
#   --open-files-in-pager, -O  grep runs a pager or editor (diff's -O<orderfile>
#                              only reads, and stays)
#   --show-signature           log/show run gpg
#   --upload-pack              fetch runs that program
#   --set-upstream             fetch writes branch config
#   --help, help <topic>       run man, info or a browser (-h prints usage)
# In every spelling: `--opt x` and `--opt=x`, a quoted or backslashed token,
# any abbreviation (parse-options takes unique prefixes: fetch --upl, cat-file
# --textc), and grep's -O clustered (-iO, -Ovim, -O vim). An abbreviation
# that is exactly another, harmless option (--text, --filter) stays. Paths
# after `--` are not flags.
_GUARD_REVIEWER_GIT_RUNS=' output ext-diff textconv filters open-files-in-pager show-signature upload-pack set-upstream help '
_guard_reviewer_git() { # <segment> -> 0 when allowed
  local -a t; read -r -a t <<<"$1"
  local i=1 n=${#t[@]} a k verb name
  for k in "${!t[@]}"; do t[k]="${t[k]//[\'\"\\]/}"; done
  while [ "$i" -lt "$n" ]; do
    case "${t[i]}" in
      -c|-c?*|--config-env|--config-env=*|--exec-path|--exec-path=*|-p|--paginate|--help) return 1 ;;
      --git-dir|--git-dir=*|--work-tree|--work-tree=*|--namespace|--namespace=*) return 1 ;;
      -C)
        [ -n "${CEL_REVIEW_CHECKOUT:-}" ] && [[ "${t[i+1]:-}" == [/~]* ]] || return 1
        _guard_norm / "${t[i+1]}" || return 1
        name="$_GN"; _guard_norm / "$CEL_REVIEW_CHECKOUT" || return 1
        [ "$name" = "$_GN" ] || return 1
        i=$((i + 2)) ;;
      --super-prefix) i=$((i + 2)) ;;
      --version|-h|-v) return 0 ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  verb="${t[i]}"
  case "$verb" in
    diff|log|show|status|rev-parse|ls-files|ls-tree|cat-file|blame|grep|merge-base|describe|range-diff|for-each-ref|show-ref|shortlog|rev-list|name-rev|version|fetch) ;;
    help)
      for a in "${t[@]:i+1}"; do
        case "$a" in -a|--all|-g|--guides) ;; *) return 1 ;; esac
      done
      return 0 ;;
    *) return 1 ;;
  esac
  for a in "${t[@]:i+1}"; do
    case "$a" in
      --) break ;;
      --text|--filter|--filter=*) ;;
      --?*)
        name="${a#--}"; name="${name%%=*}"; name="${name//[^A-Za-z-]/_}"
        [[ "$_GUARD_REVIEWER_GIT_RUNS" =~ \ ${name}[A-Za-z-]*\  ]] && return 1
        if [ "$verb" = fetch ] && [[ ' recurse-submodules recurse-submodules-default ' =~ \ ${name}[A-Za-z-]*\  ]]; then return 1; fi ;;
      -[!-]*)
        if [ "$verb" = grep ] && [[ "$a" == *O* ]]; then return 1; fi ;;
    esac
    if [ "$verb" = fetch ]; then
      case "$a" in *:*|+*|-f|--force|--refmap*) return 1 ;; esac
    fi
  done
  return 0
}

# A REVIEWER'S GIT COMMAND IS TAKEN LITERALLY. The rules above read the words
# as written; the shell may make others of them. So in a piece of the line
# that runs git: no `$` (a variable, $(...), $'...', $"..."), no backquote,
# no brace expansion ({a,b}, {a..b}) and no unquoted glob (* ? [) before a
# `--` (a PR can commit a file named --output=x) - and nothing in front of
# git that changes its environment: no VAR= assignment, no env, command,
# exec, sudo or doas. Pieces are split at ; & | ( ) and newlines, quotes
# included, which errs towards deny (_guard_reviewer_pieces). Sets _GRG to
# the piece refused.
_guard_reviewer_pieces() { # <command> -> _GRP_RAW[i], and _GRP_NORM[i] its normalised verb
  local s="${1//[;&|()]/$'\n'}"
  mapfile -t _GRP_RAW <<<"$s"
  mapfile -t _GRP_NORM < <(printf '%s\n' "${_GRP_RAW[@]}" | _guard_normalise)
}
_guard_reviewer_git_unliteral() { # (after _guard_reviewer_pieces) -> 0 when a git piece is not literal
  local i p w b
  local -a t
  for i in "${!_GRP_RAW[@]}"; do
    case "${_GRP_NORM[i]-}" in git|git\ *) ;; *) continue ;; esac
    p="${_GRP_RAW[i]}"; _GRG="$p"
    read -r -a t <<<"${p//[\'\"\\]/ }"
    for w in "${t[@]}"; do
      b="${w##*/}"
      [ "$b" != git ] || break
      [[ ! "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 0
      case "$b" in env|command|exec|sudo|doas) return 0 ;; esac
    done
    _guard_word_expands "$p" && return 0
  done
  return 1
}
_guard_word_expands() { # <one command> -> 0 when the shell would expand one of its words
  local p="$1" i c q="" w="" dd=0
  [[ "$p" == *'$'* || "$p" == *'`'* ]] && return 0
  [[ "$p" =~ \{[^}]*(,|\.\.)[^}]*\} ]] && return 0
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    if [ -n "$q" ]; then [ "$c" != "$q" ] || q=""; continue; fi
    case "$c" in
      \'|\") q="$c" ;;
      \\) i=$((i + 1)); w="${w}x" ;;
      ' '|$'\t') [ "$w" != -- ] || dd=1; w="" ;;
      '*'|'?'|'[') [ "$dd" = 1 ] || return 0; w="$w$c" ;;
      *) w="$w$c" ;;
    esac
  done
  return 1
}
# NOR DOES IT CHANGE GIT'S ENVIRONMENT FOR LATER: its shell may persist
# between commands, so a piece (other than a cel or gh command, whose text is
# mail or a comment) that sets, exports, declares, reads into or unsets a
# GIT_* or PAGER variable, or a variable whose name is an expansion
# (_guard_env_name_expansion), is refused. The launch pins them (lib/run.sh
# _run_reviewer_git_env).
_GUARD_REVIEWER_ENV='GIT_[A-Za-z0-9_]*|PAGER'
_guard_reviewer_env_tamper() { # (after _guard_reviewer_pieces) -> 0 when a piece does
  local i p re1 re2
  re1='(^|[^A-Za-z0-9_])('"$_GUARD_REVIEWER_ENV"')='
  re2='(^|[[:space:]`])(export|declare|typeset|local|readonly|unset|env|read|mapfile|readarray|printf)[[:space:]](.*[^A-Za-z0-9_$])?('"$_GUARD_REVIEWER_ENV"')([^A-Za-z0-9_]|$)'
  for i in "${!_GRP_RAW[@]}"; do
    case "${_GRP_NORM[i]-}" in cel|cel\ *|gh|gh\ *) continue ;; esac
    p="${_GRP_RAW[i]}"
    if [[ "$p" =~ $re1 ]] || [[ "$p" =~ $re2 ]] || _guard_env_name_expansion "$p"; then return 0; fi
  done
  return 1
}
_GUARD_REVIEWER_CEL='^cel$|^cel (help|version|status|fleet|profiles|budget|people)( |$)|^cel solo (review|approvals)( |$)|^cel inbox( |$)|^cel preview( |$)|^cel serve (list|start|stop)( |$)|^cel forge (pr (view|checks|reviews|list)|run (list|view|logs)|repo|whoami)( |$)|^cel (decide|learn) list( |$)|^cel sessions( --json)?$'
_GUARD_REVIEWER_GH='^gh$|^gh (help|version|status|search|browse|auth status|api|pr (view|diff|checks|list|status|comment|review)|issue (view|list|comment)|run (view|list|watch)|repo view)( |$)'
_guard_reviewer() { # <command> -> allow | deny <reason>
  local seg _GRG=""
  local -a _GRP_RAW=() _GRP_NORM=()
  if _guard_forge_raw_write "$1" || _guard_gh_api_writes "$1"; then
    printf 'deny a reviewer changes no forge state by hand - it records its own verdict (cel solo review) and reports to the product'"'"'s agent'
    return 0
  fi
  # The two checks below fork once, and only for a line that could fail them.
  if [[ "$1" == *git* || "$1" == *GIT_* || "$1" == *PAGER* || "$1" == *'$'* || "$1" == *'`'* ]]; then
    _guard_reviewer_pieces "$1"
    if _guard_reviewer_env_tamper; then
      printf 'deny a reviewer sets, exports, reads into and unsets no GIT_* or PAGER variable, nor one whose name is an expansion - git reads them before its options, and the reviewer'"'"'s launch fixes them'
      return 0
    fi
    if _guard_reviewer_git_unliteral; then
      printf 'deny a reviewer'"'"'s git command is taken literally: no $, backquote, brace expansion or unquoted glob before --, and no VAR= or env/command/exec/sudo in front of git - spell the words out: %s' "$_GRG"
      return 0
    fi
  fi
  while IFS= read -r seg || [ -n "$seg" ]; do
    case "$seg" in
      git|git\ *)
        _guard_reviewer_git "$seg" || { printf 'deny a reviewer runs read-only git (diff, log, show, status, rev-parse, ls-files, cat-file, blame, grep, merge-base, describe, fetch into remote-tracking refs), and none of the flags that write a file, run a program or pager, change config or point git at another repository (--output, --ext-diff, --textconv, --filters, grep -O/--open-files-in-pager, --show-signature, -p/--paginate, --help, --upload-pack, --set-upstream, fetch --recurse-submodules, -c, --git-dir, --work-tree, --namespace, -C outside its own checkout) - it writes no repository and judges the PR as pushed: %s' "$seg"; return 0; } ;;
      cel|cel\ *)
        [[ "$seg" =~ $_GUARD_REVIEWER_CEL ]] || { printf 'deny a reviewer runs only cel solo review|approvals, inbox, preview, serve list|start|stop, forge reads, fleet, status, profiles, budget, people, decide|learn list and help - the product'"'"'s agent does the rest: %s' "$seg"; return 0; } ;;
      gh\ *)
        [[ "$seg" =~ $_GUARD_REVIEWER_GH ]] || { printf 'deny a reviewer runs only gh reads, gh pr comment and gh pr review --comment - merging, closing, editing and checking out are the product'"'"'s agent'"'"'s: %s' "$seg"; return 0; } ;;
      herdr\ *)
        if [[ "$seg" =~ ^herdr\ (agent\ (start|stop|prompt|focus)|worktree|pane\ (close|split|send-text|send-keys|run)|(tab|workspace)\ (create|close))(\ |$) ]]; then
          printf 'deny a reviewer starts, stops and types into no agents or panes - ask the product'"'"'s agent'; return 0
        fi ;;
    esac
  done < <(_guard_segments "$1")
  printf allow
}

guard_classify() { # <role> <command>
  local role="$1" raw="$2" cmd
  # The commands the line runs, one per line, as bash reads it (_guard_lines):
  # every rule that looks for a COMMAND reads this. The tripwires that look
  # for a NAME anywhere in the text - the forge token, lib/forge.sh, a CEL_*
  # variable, the suite's environment, a team launch token - read every
  # character of it, heredoc bodies included.
  cmd="$(_guard_lines "$raw")"
  # Every role, `other` included (a reviewer stands outside any workspace).
  if _guard_names_forge_token "$raw"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_forge_verdict "$raw"; then printf '%s' "$_GUARD_FORGE_VERDICT_DENY"; return 0; fi
  if _guard_gh_alias_write "$cmd"; then printf '%s' "$_GUARD_GH_ALIAS_DENY"; return 0; fi
  if _guard_forge_lib "$raw"; then printf '%s' "$_GUARD_FORGE_LIB_DENY"; return 0; fi
  if _guard_cel_env_tamper "$raw"; then printf '%s' "$_GUARD_CEL_ENV_DENY"; return 0; fi
  if _guard_suite_tamper "$raw"; then printf '%s' "$_GUARD_SUITE_TAMPER_DENY"; return 0; fi
  if _guard_gateway_rotate "$cmd"; then printf '%s' "$_GUARD_GATEWAY_ROTATE_DENY"; return 0; fi
  if _guard_cmd_reaches_launch "$raw"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  # cel team add's launcher is not a door any agent opens by hand - `other`
  # (a reviewer) included: a member is added, and admitted against the box
  # budget, by `cel team add`.
  if _guard_starts "$cmd" 'cel run member'; then
    printf 'deny cel run member is cel team add'"'"'s internal launcher - add a member with: cel team add <feature> <role> [--focus f] [--repo r]'
    return 0
  fi
  # AN OWNER QUESTION IS ANSWERED BY A PERSON: no builder or coordinator
  # answers or drops one (cel decide refuses any agent too). Core is not
  # listed: it relays the owner's word on an unrouted question.
  if { [[ " solo orchestrator root member " == *" $role "* ]] || [ "${CEL_ROLE:-}" = lead ]; } \
    && _guard_starts "$cmd" 'cel decide (answer|drop)'; then
    printf 'deny an agent does not answer or drop an owner question - a person does (cel decide answer|drop, or the dashboard); withdraw your own with cel decide withdraw <id> --why <text>'
    return 0
  fi
  # A member or a reviewer (by role, or by its launch's CEL_ROLE, whatever
  # directory it stands in) shares its product agent's Rex session.
  if { [ "$role" = member ] || [ "${CEL_ROLE:-}" = member ] || [ "${CEL_ROLE:-}" = reviewer ]; } && _guard_rex_writes "$cmd"; then
    printf 'deny a team member or reviewer is a window in its product agent'"'"'s Rex session: it runs only read-only rex commands (ls, inspect, capture, block call process) - ask the product agent'
    return 0
  fi
  # A reviewer is judged by its launch role alone, wherever it stands: a
  # reviewer pane under a workspace is not that workspace's root.
  if [ "${CEL_ROLE:-}" = reviewer ]; then _guard_reviewer "$cmd"; return 0; fi
  if [ "$role" = core ]; then
    local cd; cd="$(_guard_core "$cmd")"
    [ -z "$cd" ] || { printf '%s' "$cd"; return 0; }
  fi
  # `other` is not the plane's concern.
  case "$role" in solo) _guard_solo "$cmd"; return 0;; esac
  case "$role" in member) _guard_member "$cmd"; return 0;; esac
  case "$role" in other) printf allow; return 0;; esac

  # A forge changed by hand (curl at its API, tea), anywhere in the line.
  if _guard_forge_raw_write "$cmd"; then
    printf 'deny orchestrators do not change forge state directly - the product'"'"'s solo agent opens PRs and lands them (cel solo land)'
    return 0
  fi
  # Opening a PR is not an orchestrator's: the solo agent opens PRs, an
  # orchestrator reads them.
  if _guard_starts "$cmd" 'cel forge pr create'; then
    printf 'deny the product'"'"'s solo agent opens pull requests; an orchestrator reads them (cel forge pr view|checks|reviews|list)'
    return 0
  fi
  # Closing and readying a PR is the product's own agent's: its orchestrator
  # may (on its own account's PRs - cel forge checks), the workspace root may not.
  if [ "$role" = root ] && _guard_starts "$cmd" 'cel forge pr (close|ready)' 'cel forge run rerun'; then
    printf 'deny the workspace root closes, readies and reruns nothing on a forge; the product'"'"'s own agent does'
    return 0
  fi
  # The orchestrator's own checkout state: see _guard_orch_owns_checkout above
  # (one command, never a chain). Root is untouched - its rules below already
  # allow git in its config repo and deny anything reaching into repos/ or a
  # herdr worktree.
  if [ "$role" = orchestrator ] && _guard_orch_owns_checkout "$cmd"; then
    printf allow; return 0
  fi
  # THE REST IS JUDGED ONE COMMAND AT A TIME, and the line's verdict is the
  # strictest of its commands': a sanctioned command allows itself, never the
  # commands chained or written after it (`cel fleet; gh pr merge 3`). Every
  # command is normalised in one pass, beside it line for line.
  # Root's git writes are its own config repo's unless the line reaches INTO
  # a product checkout (repos/, also by an earlier cd) or a herdr worktree.
  local i product=1
  if [ "$role" = root ]; then
    product=0
    case "$cmd" in *repos/*|*.herdr/worktrees*|*\ -C\ *) product=1;; esac
  fi
  local -a segs heads
  mapfile -t segs <<<"$cmd"
  mapfile -t heads < <(printf '%s\n' "${segs[@]}" | _guard_normalise)
  for i in "${!segs[@]}"; do
    [[ "${segs[i]}" == *[![:space:]]* ]] || continue
    _guard_orch_command "${segs[i]}" "${heads[i]-}" "$product" || { printf '%s' "$_GO_DENY"; return 0; }
  done
  printf allow
}

# ONE COMMAND of an orchestrator-class line (orchestrator, root, core), with
# its normalised verb: 0 allows it, 1 refuses it with the reason in _GO_DENY.
_guard_orch_command() { # <command> <its verb> <1: a git write is a product write>
  local cmd="$1" head="$2" product="$3"
  # The sanctioned commands. These are the mechanism; refusing them would
  # refuse the orchestrator's actual job - and one allows only itself.
  case "$head" in
    cel|cel\ *|cel-linear|cel-linear\ *) return 0;;
    gh\ pr\ comment|gh\ pr\ comment\ *|gh\ pr\ review|gh\ pr\ review\ *|gh\ issue\ comment|gh\ issue\ comment\ *|gh\ pr\ checks|gh\ pr\ checks\ *)
      return 0;;
  esac
  # Every refusal below names git, herdr, gh or repos/.
  case "$cmd" in *git*|*herdr*|*gh\ *|*repos/*) ;; *) return 0;; esac

  # Repository mutation. An ORCHESTRATOR's cwd is a product checkout, so any
  # git write from it is a product write - denied, in its own checkout or a
  # herdr worktree alike. ROOT's cwd is the workspace directory, which is
  # itself a small git repo of config (workspace.yaml, layouts, notes) that
  # root and the owner legitimately commit to (<product> says which).
  if _guard_git_writes "$cmd"; then
    if [ "$product" -eq 1 ]; then
      _GO_DENY='deny orchestrators do not write to repositories - the product'"'"'s solo agent builds it, opens the PR and lands it (cel solo land)'
      return 1
    fi
  fi

  # Worktrees belong to the solo agent that builds in them. A direct
  # `herdr worktree remove --force` from a coordinator can destroy unlanded work.
  case "$cmd" in
    *herdr\ worktree\ remove*|*herdr\ worktree\ create*)
      _GO_DENY='deny herdr worktree is not called from an orchestrator pane; the product'"'"'s solo agent manages its own worktrees'
      return 1;;
  esac

  # Anything that changes GitHub state. Merging in particular has exactly one
  # path, and it is the one that checks whose PR it is.
  case "$cmd" in
    *gh\ pr\ merge*|*gh\ pr\ close*|*gh\ pr\ ready*|*gh\ pr\ edit*|*gh\ pr\ create*|*gh\ pr\ reopen*)
      _GO_DENY='deny the product'"'"'s solo agent opens and updates PRs and lands them (cel solo land), which checks review and CI'
      return 1;;
    *gh\ release\ *|*gh\ repo\ *|*gh\ api\ *-X\ *|*gh\ api\ *--method*|*gh\ api\ *\ -[fF]\ *|*gh\ api\ *--field*|*gh\ api\ *--raw-field*)
      _GO_DENY='deny orchestrators do not change GitHub state directly'
      return 1;;
  esac

  # Editing files under repos/ by shell. (The native edit tools are checked
  # separately by the hook, by path.)
  if _guard_shell_edits_repos "$cmd"; then
    _GO_DENY='deny orchestrators do not edit files under repos/ - the product'"'"'s solo agent does'
    return 1
  fi
  return 0
}

# For the native edit tools (Edit/Write/MultiEdit/NotebookEdit), which never
# pass through a shell: a path under any workspace's repos/ is a repository
# write. Everything else - specs and notes under <ws>/.cel/, the workspace
# file, scratch - is the orchestrator's to write. The forge token is nobody's.
guard_classify_path() { # <role> <file_path>
  local role="$1" path="$2"
  if _guard_names_forge_token "$path"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_path_reaches_launch "$path"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  if [ "$role" = member ]; then _guard_member_path "$path"; return 0; fi
  # Core writes its own notes and nothing else: it has no workspace, so every
  # path outside its directory belongs to someone whose job it is not.
  if [ "$role" = core ]; then
    local core="${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"
    case "$path" in
      "$core"/*) printf allow; return 0;;
      *) printf 'deny core writes only its own notes (%s) - a product agent changes everything else; send it the request' "$core"; return 0;;
    esac
  fi
  case "$role" in solo|other) printf allow; return 0;; esac
  case "$path" in
    */repos/*) printf 'deny orchestrators do not edit files under repos/ - the product'"'"'s solo agent does'; return 0;;
  esac
  printf allow
}

# For the native read tools (Read, read): every role reads freely - except the
# forge token and the team launch tokens.
guard_classify_read() { # <role> <file_path>
  if _guard_names_forge_token "$2"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_path_reaches_launch "$2"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  printf allow
}
