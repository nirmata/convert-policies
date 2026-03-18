#!/usr/bin/env bash
# Run nctl AI conversion; output is used for flow checks only (not saved to results/).
set -e

INPUT="${1:-input/require-resource-limits.yaml}"
PROMPT="Convert the policy in ${INPUT} to a Kyverno ValidatingPolicy (Kyverno 1.16+) using CEL-based validation where appropriate. Write the converted policy to output/converted.yaml."

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${REPO_ROOT}/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE=$(mktemp)
POLICY_NAME=$(basename "$INPUT" .yaml)
MANIFEST_DIR="${RESULTS_DIR}/policy-output-manifest-files"

mkdir -p "$RESULTS_DIR"
mkdir -p "$MANIFEST_DIR"
mkdir -p "${REPO_ROOT}/output"

{
  echo "=== nctl version ==="
  nctl version 2>&1 || true
  echo ""
  echo "=== nctl ai (full output) ==="
  echo "Prompt: $PROMPT"
  echo ""
} | tee "$LOG_FILE"

echo "Running nctl ai..."
# --skip-permission-checks: skip interactive prompts (e.g. "Does this capture the policy intent?") so conversion runs non-interactively
nctl ai --allowed-dirs "$REPO_ROOT" --prompt "$PROMPT" --skip-permission-checks 2>&1 | tee -a "$LOG_FILE"

echo ""
# Conversion step results (same style as validation step)
CONVERTING="Reading file from ~/.nirmata/nctl/skills/policy-skills/converting-policies/SKILL.md"
GENERATING="Reading file from ~/.nirmata/nctl/skills/policy-skills/generating-policies/SKILL.md"
AGENT_OK="✅ Agent completed successfully!"

check_converting=0
check_generating=0
check_agent=0
grep -qF "$CONVERTING" "$LOG_FILE" 2>/dev/null && check_converting=1
grep -qF "$GENERATING" "$LOG_FILE" 2>/dev/null && check_generating=1
grep -qF "$AGENT_OK" "$LOG_FILE" 2>/dev/null && check_agent=1

echo "  📋 Conversion step results"
echo "  ────────────────────────────────────────"
if [ "$check_converting" -eq 1 ]; then
  echo "  1. Converting-policies skill   ✅  PASS  — conversion skill was loaded"
else
  echo "  1. Converting-policies skill   ❌  FAIL  — conversion skill not detected in log"
fi
if [ "$check_generating" -eq 1 ]; then
  echo "  2. Generating-policies skill   ✅  PASS  — policy generation skill was loaded"
else
  echo "  2. Generating-policies skill   ❌  FAIL  — policy generation skill not detected in log"
fi
if [ "$check_agent" -eq 1 ]; then
  echo "  3. Agent completion            ✅  PASS  — nctl AI agent finished successfully"
else
  echo "  3. Agent completion            ❌  FAIL  — agent did not complete successfully"
fi
CONVERTED_YAML="${REPO_ROOT}/output/converted.yaml"
SAVED_POLICY="${MANIFEST_DIR}/${POLICY_NAME}_${TIMESTAMP}.yaml"
if [ -f "$CONVERTED_YAML" ]; then
  cp "$CONVERTED_YAML" "$SAVED_POLICY"
  echo "  📁 Saved policy: ${SAVED_POLICY}"
fi
echo "  ────────────────────────────────────────"
rm -f "$LOG_FILE"
echo ""

if [ "$check_converting" -eq 1 ] && [ "$check_generating" -eq 1 ] && [ "$check_agent" -eq 1 ]; then
  exit 0
else
  exit 1
fi
