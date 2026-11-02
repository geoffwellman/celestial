# shellcheck shell=bash
# A box without flock(1). flock lives in /usr/bin beside everything else, so
# the PATH this prints swaps /usr/bin and /bin for a directory of links to
# every one of their programs except flock; the rest of PATH is kept in order.
no_flock_path() { # <scratch dir> -> PATH with no flock on it
  local d="$1/no-flock-bin" b dir out=""
  mkdir -p "$d"
  for b in /usr/bin/* /bin/*; do
    case "${b##*/}" in flock) continue ;; esac
    [ -e "$d/${b##*/}" ] || [ -L "$d/${b##*/}" ] || ln -s "$b" "$d/${b##*/}" 2>/dev/null || true
  done
  local IFS=:
  for dir in $PATH; do
    case "$dir" in /usr/bin|/bin|/usr/bin/|/bin/) continue ;; esac
    [ -x "$dir/flock" ] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s' "${out:+$out:}$d"
}
