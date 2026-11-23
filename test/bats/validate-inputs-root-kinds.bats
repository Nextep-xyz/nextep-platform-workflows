#!/usr/bin/env bats
# validate-inputs.sh — the optional input root-kinds (K1): the kind of each root of the repository, a JSON object {"<root>": "<kind>"}.
# A malformed value is a defect of the caller's configuration, so it FAILS the job naming the input (it is not a report). Flows: cicd, and
# node-ci (the flow lego-node-ci uses: it has none of the other inputs, so only this one is checked).

load 'helpers'

run_validate() { run "$SCRIPTS/validate-inputs.sh" "$1"; }

# bad_value <flow> <value> [<expected fragment>]: the value is refused, naming the input (and the fragment when given)
bad_value() {
  local flow=$1 value=$2 fragment=${3:-}
  if [[ $flow == cicd ]]; then cicd_ecs_env; else common_env; fi
  export INPUT_ROOT_KINDS="$value"
  run_validate "$flow"
  [ "$status" -eq 1 ] || { echo "[$flow] '$value' was accepted: $output"; return 1; }
  [[ "$output" == *"input 'root-kinds'"* ]] || { echo "[$flow] '$value': the error does not name the input: $output"; return 1; }
  [[ -z $fragment || "$output" == *"$fragment"* ]] || { echo "[$flow] '$value': expected '$fragment' in: $output"; return 1; }
}

@test "K1: a valid declaration passes in both flows (the shape of the real caller: the repository root and its infra root)" {
  local v
  for v in '{".":"frontend","infra":"iac"}' '{".":"backend","infra":"iac"}' '{"infra":"iac"}' '{".":"platform"}' '{"apps/web":"frontend","apps/api":"backend","infra":"iac"}'; do
    cicd_ecs_env
    export INPUT_ROOT_KINDS="$v"
    run_validate cicd
    [ "$status" -eq 0 ] || { echo "cicd '$v': $output"; return 1; }
    common_env
    export INPUT_ROOT_KINDS="$v"
    run_validate node-ci
    [ "$status" -eq 0 ] || { echo "node-ci '$v': $output"; return 1; }
  done
}

@test "K1: the input left empty (the default of every existing caller) changes nothing" {
  cicd_ecs_env
  export INPUT_ROOT_KINDS=""
  run_validate cicd
  [ "$status" -eq 0 ]
  common_env
  run_validate node-ci
  [ "$status" -eq 0 ]
}

@test "K1: JSON that is not valid, and JSON that is not an object, are refused" {
  local flow v
  for flow in cicd node-ci; do
    for v in 'not json' '{' '{".":"iac"' '["iac"]' '"iac"' '42' 'true' 'null' "{'.':'iac'}"; do
      bad_value "$flow" "$v" "must be a JSON object"
    done
  done
}

@test "K1: an empty object is an oversight, not a declaration" {
  bad_value cicd '{}' "at least one root"
  bad_value node-ci '{}' "at least one root"
}

@test "K1: a root that is absolute, climbs with .., has a backslash, a glob, a comma, a trailing slash, a space or is empty is refused (the rule of install-dirs)" {
  local flow v
  for flow in cicd node-ci; do
    for v in '{"/abs":"iac"}' '{"..":"iac"}' '{"../infra":"iac"}' '{"a/../b":"iac"}' '{"infra\\win":"iac"}' '{"infra/*":"iac"}' '{"*":"iac"}' \
      '{"a,b":"iac"}' '{"infra/":"iac"}' '{"my infra":"iac"}' '{"":"iac"}' '{"./infra":"iac"}' '{"a\nb":"iac"}' '{"-x":"iac"}'; do
      bad_value "$flow" "$v" "invalid root"
    done
  done
}

@test "K1: a kind outside the vocabulary is refused, and the message lists the valid ones" {
  local flow v
  for flow in cicd node-ci; do
    for v in '{".":"app"}' '{".":"IAC"}' '{".":"Frontend"}' '{".":""}' '{".":"iac "}' '{".":"iac backend"}' '{".":"infra"}' '{".":"library"}'; do
      bad_value "$flow" "$v" "valid kinds: iac, backend, frontend, platform"
    done
  done
}

@test "K1: a value that is not a string is refused naming the root" {
  local v
  for v in '{".":1}' '{".":null}' '{".":true}' '{".":["iac"]}' '{".":{"kind":"iac"}}'; do
    bad_value cicd "$v" "the kind of root '.' must be a string"
  done
}

@test "K1: every problem is reported, not only the first (one bad root and one bad kind)" {
  cicd_ecs_env
  export INPUT_ROOT_KINDS='{"/abs":"iac","infra":"nope"}'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid root '/abs'"* ]]
  [[ "$output" == *"root 'infra' has the kind 'nope'"* ]]
}

@test "K1: what comes from the caller cannot reshape the error: a crafted key or kind is shown sanitised and cut" {
  local long
  long="$(printf 'x%.0s' {1..200})"
  cicd_ecs_env
  export INPUT_ROOT_KINDS="{\"::error::pwned\":\"iac\",\".\":\"$long\"}"
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" != *"::error::pwned"* ]]
  [[ "$output" != *"$long"* ]]
  [[ "$output" == *"invalid root '??error??pwned'"* ]]
}

@test "K1: node-ci checks root-kinds and nothing else (no project, environment or compute needed)" {
  : # an empty environment of inputs (no INPUT_PROJECT, INPUT_COMPUTE...) must not make the flow ask for them
  unset INPUT_PROJECT INPUT_ENVIRONMENT INPUT_COMPUTE INPUT_ROOT_KINDS
  export INPUT_ROOT_KINDS='{".":"frontend","infra":"iac"}'
  run_validate node-ci
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"inputs OK (flow=node-ci)"* ]]
}

@test "K1: the input arrives inside INPUTS_JSON like every other (toJSON(inputs) of the calling workflow)" {
  unset INPUT_ROOT_KINDS
  INPUTS_JSON='{"node-version":"22","packages-evidence":true,"root-kinds":"{\".\":\"frontend\",\"infra\":\"iac\"}"}' run_validate node-ci
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  INPUTS_JSON='{"node-version":"22","root-kinds":"{\".\":\"nope\"}"}' run_validate node-ci
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'root-kinds'"* ]]
}

@test "an unknown flow is still refused" {
  run_validate nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flow"* ]]
}
