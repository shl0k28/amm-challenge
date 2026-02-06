#!/usr/bin/env bash
set -euo pipefail

# Quick local parameter sweep for Strategy.sol constants.
# Usage:
#   scripts/sweep_v4.sh [simulations]
# Example:
#   scripts/sweep_v4.sh 30

SIMULATIONS="${1:-30}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATEGY_FILE="${ROOT_DIR}/Strategy.sol"
TMP_DIR="$(mktemp -d -t v4sweep)"
RESULTS_FILE="${TMP_DIR}/results.csv"

if [[ ! -f "${STRATEGY_FILE}" ]]; then
  echo "Strategy file not found: ${STRATEGY_FILE}" >&2
  exit 1
fi

if ! command -v amm-match >/dev/null 2>&1; then
  echo "amm-match not found in PATH. Activate your venv first." >&2
  exit 1
fi

touch "${RESULTS_FILE}"

echo "Sweeping Strategy constants with ${SIMULATIONS} simulations per candidate..."
echo "temp dir: ${TMP_DIR}"

for low in 60 62 64 66; do
  min=$((low - 5))
  for toxdiv in 2 3; do
    for toxratio in 6 7; do
      for rebate in 0 1 2; do
        candidate="${TMP_DIR}/cand_${low}_${min}_${toxdiv}_${toxratio}_${rebate}.sol"
        cp "${STRATEGY_FILE}" "${candidate}"
        LC_ALL=C perl -0pi -e \
          "s/LOW_FEE = \\d+ \\* BPS;/LOW_FEE = ${low} * BPS;/; \
           s/MIN_DYNAMIC_FEE = \\d+ \\* BPS;/MIN_DYNAMIC_FEE = ${min} * BPS;/; \
           s/TOX_TO_FEE_DIV = \\d+;/TOX_TO_FEE_DIV = ${toxdiv};/; \
           s/TOX_RATIO_DIV = \\d+;/TOX_RATIO_DIV = ${toxratio};/; \
           s/INTRASTEP_REBATE = \\d+ \\* BPS;/INTRASTEP_REBATE = ${rebate} * BPS;/;" \
          "${candidate}"

        edge="$(amm-match run "${candidate}" --simulations "${SIMULATIONS}" | tail -n 1 | sed -E 's/.*Edge: ([0-9.-]+)/\1/')"
        echo "${low},${min},${toxdiv},${toxratio},${rebate},${edge},${candidate}" >> "${RESULTS_FILE}"
        printf "low=%s min=%s toxdiv=%s toxratio=%s rebate=%s edge=%s\n" \
          "${low}" "${min}" "${toxdiv}" "${toxratio}" "${rebate}" "${edge}"
      done
    done
  done
done

echo
echo "Top 10:"
sort -t, -k6,6nr "${RESULTS_FILE}" | head -n 10
echo
echo "Full results: ${RESULTS_FILE}"
