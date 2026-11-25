# shellcheck shell=bash
# What comes from the repository (a root key of root-kinds, a directory name, a package name, a version) is data, never markup: before it is
# printed in an annotation or in the summary it is reduced to a small alphabet. Anything outside becomes '?', so a crafted value cannot
# inject a workflow command (%0A, ::error::), a Markdown table cell (|) or a code span (backtick). One definition for the evidence and the policy.

# safe_path <s>: a root or a directory (A-Z a-z 0-9 . _ / -), 60 characters at most
safe_path() {
  local s=${1-}
  s=${s//[^A-Za-z0-9._\/-]/?}
  printf '%s' "${s:0:60}"
}

# safe_name <s>: a package name (adds @), 80 characters at most
safe_name() {
  local s=${1-}
  s=${s//[^A-Za-z0-9._@\/-]/?}
  printf '%s' "${s:0:80}"
}

# safe_version <s>: a version (adds +), 40 characters at most
safe_version() {
  local s=${1-}
  s=${s//[^A-Za-z0-9._+-]/?}
  printf '%s' "${s:0:40}"
}

# safe_detail <s>: a sentence written by the platform around the values above (adds space , : ' ( ) = @), 300 characters at most
safe_detail() {
  local s=${1-}
  s=${s//[^A-Za-z0-9 ._@\/:,\'()=+-]/?}
  printf '%s' "${s:0:300}"
}
