#!/usr/bin/env bats
# validate-inputs.sh — python-version and python-requirements (G-PY1, G-PY2), in both flows.

load 'helpers'

run_validate() { run "$SCRIPTS/validate-inputs.sh" "$1"; }

@test "G-PY1: python-version accepts 3.N and 3.N.P only" {
  local v
  for v in 3.12 3.9 3.12.7 3.13.0; do
    cicd_ecs_env
    export INPUT_PYTHON_VERSION="$v" INPUT_PYTHON_REQUIREMENTS=requirements.txt
    run_validate cicd
    [ "$status" -eq 0 ] || { echo "$v: $output"; return 1; }
  done
  for v in 3 3.12.7.1 4.0 2.7 "3.12 " v3.12 3.x 3.12-dev ">=3.12" latest "3.123"; do
    cicd_ecs_env
    export INPUT_PYTHON_VERSION="$v" INPUT_PYTHON_REQUIREMENTS=requirements.txt
    run_validate cicd
    [ "$status" -eq 1 ] || { echo "'$v' was accepted"; return 1; }
    [[ "$output" == *"input 'python-version'"* ]] || { echo "'$v': $output"; return 1; }
  done
}

@test "G-PY2: python-version and python-requirements go together, in both flows" {
  cicd_ecs_env
  export INPUT_PYTHON_VERSION=3.12 INPUT_PYTHON_REQUIREMENTS=""
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"'python-version' needs 'python-requirements'"* ]]
  env_deploy_env
  export INPUT_PYTHON_VERSION="" INPUT_PYTHON_REQUIREMENTS=requirements.txt
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"'python-requirements' needs 'python-version'"* ]]
  env_deploy_env
  export INPUT_PYTHON_VERSION=3.12 INPUT_PYTHON_REQUIREMENTS=requirements.txt,requirements-dev.txt
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "G-PY2: python-requirements follows the path rules of install-dirs (no '..', no spaces, no trailing '/', no empty entry)" {
  local p
  for p in ../requirements.txt /abs/requirements.txt "my reqs.txt" "a;b.txt" "req/" "a.txt,,b.txt" "."; do
    cicd_ecs_env
    export INPUT_PYTHON_VERSION=3.12 INPUT_PYTHON_REQUIREMENTS="$p"
    run_validate cicd
    [ "$status" -eq 1 ] || { echo "'$p' was accepted"; return 1; }
    [[ "$output" == *"input 'python-requirements'"* ]] || { echo "'$p': $output"; return 1; }
  done
  cicd_ecs_env
  export INPUT_PYTHON_VERSION=3.12 INPUT_PYTHON_REQUIREMENTS=backend/requirements.txt,backend/requirements-dev.txt
  run_validate cicd
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "python inputs left empty change nothing for a caller that does not use them" {
  cicd_ecs_env
  run_validate cicd
  [ "$status" -eq 0 ]
  env_deploy_env
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}
