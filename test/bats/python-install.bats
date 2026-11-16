#!/usr/bin/env bats
# python-install.sh — validates every requirements file BEFORE installing anything (pins only, no source options),
# then installs them in order with pip. `python` is a fake that records its calls. Fixtures: test/fixtures/python.

load 'helpers'

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/bin"
  cp -r "$REPO_ROOT/test/fixtures/python" "$REPO/py"
  cat >"$REPO/bin/python" <<'SH'
#!/usr/bin/env bash
echo "python $*" >>"$FAKE_LOG"
SH
  chmod +x "$REPO/bin/python"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  export PATH="$REPO/bin:$PATH" GITHUB_WORKSPACE="$REPO"
  cd "$REPO"
}

install_with() { PYTHON_REQUIREMENTS="$1" run "$SCRIPTS/python-install.sh"; }

@test "G-PY3: pinned requirements, hashes and nested -r/-c files are installed in the order given" {
  install_with "py/valid/pins.txt,py/valid/hashes.txt,py/valid/nested/root.txt"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l <"$FAKE_LOG")" -eq 3 ]
  [ "$(sed -n 1p "$FAKE_LOG")" = "python -m pip install --no-input --disable-pip-version-check -r py/valid/pins.txt" ]
  [[ "$(sed -n 2p "$FAKE_LOG")" == *"-r py/valid/hashes.txt" ]]
  [[ "$(sed -n 3p "$FAKE_LOG")" == *"-r py/valid/nested/root.txt" ]]
}

# <fixture>:<line>:<fragment of the reason>
@test "G-PY3: every kind of unpinned or foreign requirement is rejected naming the file and the line" {
  local case file line frag
  for case in \
    range-ge:3:"range" range-compatible:3:"range" range-lt:3:"range" range-ne:3:"range" range-wildcard:3:"range" \
    unversioned:3:"has no version" editable:3:"editable" url:3:"URL or VCS" vcs:3:"URL or VCS" \
    index-url:3:"'--index-url'" extra-index-url:3:"'--extra-index-url'" find-links:3:"'--find-links'" \
    trusted-host:3:"'--trusted-host'" other-option:3:"unsupported option" bad-hash:3:"hash" \
    outside:3:"outside the repository" missing:3:"not found"; do
    IFS=: read -r file line frag <<<"$case"
    : >"$FAKE_LOG"
    install_with "py/invalid/$file.txt"
    [ "$status" -eq 1 ] || { echo "$file: expected failure, got $status"; return 1; }
    [[ "$output" == *"py/invalid/$file.txt:$line:"* ]] || { echo "$file: no file:line in: $output"; return 1; }
    [[ "$output" == *"$frag"* ]] || { echo "$file: expected '$frag' in: $output"; return 1; }
    [ ! -s "$FAKE_LOG" ] || { echo "$file: pip ran although the file is invalid"; return 1; }
  done
}

@test "G-PY3: a -r cycle and a -r chain deeper than 3 are rejected" {
  install_with "py/invalid/cycle-a.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
  [[ "$output" == *"py/invalid/cycle-b.txt:2:"* ]]
  install_with "py/chain/d0.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"deeper than 3"* ]]
  [[ "$output" == *"py/chain/d3.txt:1:"* ]]
}

@test "G-PY3: every invalid fixture on disk is rejected and every valid one passes (a new file is covered without editing this test)" {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    install_with "$f"
    [ "$status" -eq 1 ] || { echo "$f was accepted"; return 1; }
    [[ "$output" == *"$f:"* || "$output" == *"py/invalid/"* ]] || { echo "$f: the message does not name the culprit: $output"; return 1; }
  done < <(find py/invalid -type f -name '*.txt' | sort)
  ((n >= 15)) || { echo "only $n invalid fixtures discovered"; return 1; }
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    install_with "$f"
    [ "$status" -eq 0 ] || { echo "$f was rejected: $output"; return 1; }
  done < <(find py/valid -type f -name '*.txt' -not -name constraints.txt -not -name base.txt | sort)
  ((n >= 3)) || { echo "only $n valid fixtures discovered"; return 1; }
}

@test "G-PY3: all the files are validated before the first install, and every problem is reported" {
  install_with "py/valid/pins.txt,py/invalid/range-ge.txt,py/invalid/unversioned.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"py/invalid/range-ge.txt:3:"* ]]
  [[ "$output" == *"py/invalid/unversioned.txt:3:"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "G-PY3: a marker with a comparison is not a range, and a comment with >= is ignored" {
  printf '%s\n' 'tzdata==2024.1 ; python_version >= "3.9"' '# anything>=1 in a comment' >py/marker.txt
  install_with "py/marker.txt"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "python-install: a missing or empty list, a non-file and a hostile path are refused" {
  PYTHON_REQUIREMENTS="" run "$SCRIPTS/python-install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PYTHON_REQUIREMENTS"* ]]
  install_with "py/valid"
  [ "$status" -eq 1 ]
  [[ "$output" == *"py/valid"* ]]
  local p
  for p in ../x /abs "a b" "a;b" "py/valid/pins.txt/"; do
    install_with "$p"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid"* ]] || { echo "$p: $output"; return 1; }
  done
}
