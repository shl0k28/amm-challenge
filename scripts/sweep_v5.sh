#!/usr/bin/env bash
set -euo pipefail

# Sweep key V5 constants in Strategy.sol.
# Usage:
#   scripts/sweep_v5.sh [simulations]
#
# Example:
#   scripts/sweep_v5.sh 30

SIMULATIONS="${1:-30}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATEGY_FILE="${ROOT_DIR}/Strategy.sol"
TMP_DIR="$(mktemp -d -t v5sweep)"
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
echo "Sweeping V5 constants with ${SIMULATIONS} simulations per candidate..."
echo "temp dir: ${TMP_DIR}"

for low in 50 52 54 56 58; do
  min=$((low - 5))
  for vol_div in 10 12 14; do
    for cd_base in 2 3 4; do
      for cd_trigger in 180 200 220; do
        candidate="${TMP_DIR}/cand_${low}_${min}_${vol_div}_${cd_base}_${cd_trigger}.sol"
        cp "${STRATEGY_FILE}" "${candidate}"
        LC_ALL=C perl -0pi -e \
          "s/LOW_FEE = \\d+ \\* BPS;/LOW_FEE = ${low} * BPS;/; \
           s/MIN_DYNAMIC_FEE = \\d+ \\* BPS;/MIN_DYNAMIC_FEE = ${min} * BPS;/; \
           s/VOL_TO_FEE_DIV = \\d+;/VOL_TO_FEE_DIV = ${vol_div};/; \
           s/COOLDOWN_BASE_BUMP = \\d+ \\* BPS;/COOLDOWN_BASE_BUMP = ${cd_base} * BPS;/; \
           s/COOLDOWN_TRIGGER_RATIO = \\d+ \\* BPS;/COOLDOWN_TRIGGER_RATIO = ${cd_trigger} * BPS;/" \
          "${candidate}"

        edge="$(amm-match run "${candidate}" --simulations "${SIMULATIONS}" | tail -n 1 | sed -E 's/.*Edge: ([0-9.-]+)/\1/')"
        echo "${low},${min},${vol_div},${cd_base},${cd_trigger},${edge},${candidate}" >> "${RESULTS_FILE}"
        printf "low=%s min=%s vol_div=%s cd_base=%s cd_trigger=%s edge=%s\n" \
          "${low}" "${min}" "${vol_div}" "${cd_base}" "${cd_trigger}" "${edge}"
      done
    done
  done
done

echo
echo "Top 10:"
sort -t, -k6,6nr "${RESULTS_FILE}" | head -n 10
echo
echo "Full results: ${RESULTS_FILE}"
