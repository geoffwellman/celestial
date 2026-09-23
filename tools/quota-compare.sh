#!/usr/bin/env bash
# Both usage readers, side by side, per account and per window.
#
# CEL-61 made celestial read usage from CLIProxyAPI's vault; omp's path stays
# underneath until this says the two agree on the live box. It is deliberately
# a tool and not a `cel` verb: it is run by hand, once, before omp's path is
# removed in a later ticket, and it asks both sources in one go - which spends
# nothing but a status read against each provider.
#
# NO TOKEN IS PRINTED. The rows carry none, and nothing here reads a
# credential file except through lib/quota.sh, which does not print one either.
set -uo pipefail
CEL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/quota.sh
. "$CEL_ROOT/lib/quota.sh"

cpa="$( { _sub_cliproxy_rows; _sub_opencode_rows; } | jq -sc '.' 2>/dev/null || printf '[]')"
omp="$(_sub_omp_rows | jq -sc '.' 2>/dev/null || printf '[]')"

printf '  %-10s %-28s %-14s %-12s %-12s %s\n' PROVIDER ACCOUNT WINDOW cliproxy omp AGREES
jq -r --argjson a "$cpa" --argjson b "$omp" -n '
  def wins($rows): [ $rows[] | . as $r | (.windows // [])[]
                     | {k: ($r.label + "|" + $r.provider + "|" + .name
                            + (if .scope then " " + .scope else "" end)),
                        provider: $r.provider, label: $r.label,
                        window: (.name + (if .scope then " " + .scope else "" end)),
                        pct: .used_pct} ];
  (wins($a) | INDEX(.k)) as $A | (wins($b) | INDEX(.k)) as $B
  | ([($A | keys_unsorted[]), ($B | keys_unsorted[])] | unique)
  | .[]
  | . as $k
  | ($A[$k] // $B[$k]) as $any
  | [$any.provider, $any.label, $any.window,
     (if $A[$k] then ($A[$k].pct | tostring | .[0:6]) else "-" end),
     (if $B[$k] then ($B[$k].pct | tostring | .[0:6]) else "-" end),
     (if ($A[$k] and $B[$k])
      then (if (($A[$k].pct - $B[$k].pct) | fabs) < 1 then "yes" else "NO" end)
      # a window only one reader has is the interesting case: it is either a
      # row the owner would lose, or one they would gain.
      elif $A[$k] then "cliproxy only" else "omp only" end)]
  | "  " + (.[0] | .[0:10] | (. + "          ")[0:10]) + " "
         + (.[1] | .[0:28] | (. + "                            ")[0:28]) + " "
         + (.[2] | .[0:14] | (. + "              ")[0:14]) + " "
         + (.[3] | (. + "            ")[0:12]) + " "
         + (.[4] | (. + "            ")[0:12]) + " " + .[5]' 2>/dev/null

printf '\n  accounts: cliproxy %s, omp %s\n' \
  "$(printf '%s' "$cpa" | jq -r 'length')" "$(printf '%s' "$omp" | jq -r 'length')"
