# shellcheck shell=bash
# The one package whose binary is part of the standard, and the binary it installs (package -> binary). It is the contract of the packages
# evidence and of the policy: both read it from here, so the package a message names is the package the evidence ran.
# shellcheck disable=SC2034 # read by the scripts that source this file
GUARDRAILS_PACKAGE='@nextep/cdk-guardrails'
# shellcheck disable=SC2034
GUARDRAILS_BIN='nextep-guardrails'
