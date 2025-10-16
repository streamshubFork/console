#!/usr/bin/env bash
set -xeuo pipefail

# Use env variables (set in workflow)
TESTCASE="${TESTCASE:-}"
PROFILE="${PROFILE:-}"

# --- CASE 1: single testcase was provided ---
if [[ -n "$TESTCASE" ]]; then
  echo "Single testcase detected: $TESTCASE"
  echo "matrix={\"include\":[{\"testcase\":\"$TESTCASE\",\"profile\":\"$PROFILE\"}]}" >> "$GITHUB_OUTPUT"
  exit 0
fi

# --- CASE 2 OR 3: no specific testcase provided ---
echo "No specific testcase provided, generating matrix..."
FILES=$(find systemtests/src/test/java -type f -name '*ST.java' ! -name 'AbstractST.java')

MATRIX="["
SEP=""
for f in $FILES; do
  NAME=$(basename "$f" .java)
  if [[ -n "$PROFILE" ]]; then
    MATRIX+="${SEP}{\"testcase\":\"$NAME\",\"profile\":\"$PROFILE\"}"
  else
    MATRIX+="${SEP}{\"testcase\":\"$NAME\"}"
  fi
  SEP=","
done
MATRIX+="]"

echo "Matrix: $MATRIX"
echo "matrix={\"include\":$MATRIX}" >> "$GITHUB_OUTPUT"
