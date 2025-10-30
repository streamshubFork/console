#!/usr/bin/env bash
set -xeuo pipefail

# Use env variables (set in workflow)
TESTCASE="${TESTCASE:-}"
PROFILE="${PROFILE:-}"

# --- CASE 1: specific testcase provided ---
if [[ -n "$TESTCASE" ]]; then
  echo "Single testcase detected: $TESTCASE"
  echo "matrix={\"include\":[{\"testcase\":\"$TESTCASE\",\"profile\":\"$PROFILE\"}]}" >> "$GITHUB_OUTPUT"
  exit 0
fi

# --- CASE 2: specific profile provided ---
if [[ -n "$PROFILE" ]]; then
  echo "Profile detected: $PROFILE, extracting testcases from Maven..."

  MVN_OUTPUT=$(mvn clean verify -B -q -pl systemtests -P "$PROFILE" \
    | grep -A1 "TEST CLASSES TO BE EXECUTED" \
    | tail -n1 \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -E '^[A-Za-z0-9]+ST$' \
    | sort)

  if [[ -z "$MVN_OUTPUT" ]]; then
    echo "❌ ERROR: No testclasses found for profile $PROFILE"
    exit 1
  fi

  MATRIX="["
  SEP=""
  for TEST in $MVN_OUTPUT; do
    MATRIX+="${SEP}{\"testcase\":\"$TEST\",\"profile\":\"$PROFILE\"}"
    SEP=","
  done
  MATRIX+="]"

  echo "Matrix: $MATRIX"
  echo "matrix={\"include\":$MATRIX}" >> "$GITHUB_OUTPUT"
  exit 0
fi

# --- CASE 3: no TESTCASE nor PROFILE ---
echo "❌ ERROR: Neither TESTCASE nor PROFILE is set. Cannot generate matrix."
exit 1