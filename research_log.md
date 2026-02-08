# AMM Challenge Research Log

## 0) Session Goal
- Objective: break **540+ edge on local 25-sim** evaluation (targeting roughly 520+ online given observed local-online gap).
- Hard constraints: only modify `Strategy.sol`; do not edit Rust/Python simulator files.
- Reliability constraint: avoid runtime/revert patterns that pass local scoring but fail online submission.

## 1) Baseline Recovery (Last Known Working)
- Restored baseline from git `HEAD` (`e9223e0`, message `bandstrategy 507.04`).
- Baseline strategy family: **BandShield_v4-style side-specific shield**.

### Baseline Architecture Summary
- Core idea: use own reserve spot dynamics as proxy for fair-value drift and adverse-selection intensity.
- Signals:
  - Spot from reserves (`y/x`)
  - First-trade per-step classification (`likelyArb`) using trade-size ratio threshold
  - EWMA variance (`sigma` proxy)
  - EWMA arrival rate (`lambda` proxy)
  - Side streak / toxicity / shock counters
  - Inventory deviation from inferred neutral reserve
- Fee logic:
  - Defensive base fee from `CORE + k*sigma + shock`
  - Lambda adjuster: sparse flow widens, dense flow tightens
  - Side-specific no-arb shield: raise vulnerable side based on spot/fair gap
  - Safe-side rebate to preserve routing share and rebalancing flow
  - Inventory skew to discourage worsening inventory side
  - Smoothing to reduce jitter

### Baseline Known Strengths
- Robust against arb leakage relative to simple low-fee undercutting.
- Exploits asymmetry (shield one side, rebate the other) better than symmetric widening.
- Good local 25-sim results (~530 band in recent checks), historically around ~507 online.

### Baseline Known Weaknesses
- First-trade arb classification can be noisy under high retail bursts.
- Shield uses local inference and can misfire when fair drift and retail coincide.
- Can be too defensive on benign windows, giving up retail share.
- Can remain too permissive exactly at regime transitions (toxic first-trade timing).
- Some variants in this family have shown online instability; avoid over-complex fragile state.

## 2) Market/Microstructure Notes (Design Priors)

### 2.1 Orderbook Dynamics Analogy for CFMM Routing
- In CEX microstructure, spread compensates adverse selection and inventory risk; here fee plays that role.
- Routing split is effectively a continuous quote-competition game:
  - lower fee increases effective depth share nonlinearly
  - being slightly above peer fee can sharply reduce flow share
- Marginal quote quality matters more than static average fee; fee jitter can leak share.

### 2.2 Dynamic Fee Principles
- Adverse selection costs scale with variance and stale-quote exposure.
- Optimal fee should increase with volatility and informed-flow probability.
- Inventory-aware asymmetry dominates symmetric widening:
  - widen side that worsens inventory
  - tighten side that rebalances
- Two-timescale control usually beats single-rule control:
  - slow loop for regime inference (sigma/lambda)
  - fast loop for toxicity shocks

### 2.3 AMM-Specific Lessons
- In this simulator, arbitrage hits first each step, then retail follows.
- Fee chosen after a trade is effectively a quote for unknown next event timing.
- The dangerous edge case is ending a step with too-low carry fee and getting hit by next-step arb.
- Therefore, continuation rebates must be probabilistic and bounded by carry-risk.

### 2.4 Practical Learnings from Prior Iterations
- Pure low-fee harvest modes underperform due arb bleed.
- Pure high-fee armor modes underperform due retail starvation.
- Best region tends to be defensive carry + selective safe-side rebate + bounded shield.
- Overly complicated fair estimators can improve in-sample then fail out-of-sample or online reliability.

## 3) Candidate Architecture Approaches

## Approach A: Regime-Ladder + Toxicity FSM (chosen)
- Description:
  - explicit hidden-state ladder: `CALM`, `TRANSITION`, `STORM`
  - slow regime score from sigma/lambda EWMAs
  - fast toxicity FSM from first-trade size, side streak, and shock events
  - fee = regime_base + toxicity_overlay + inventory_skew + side shield
- Pros:
  - clean separation of slow/fast effects
  - easier to reason about and tune safely
  - robust carry control for next-step arb risk
- Cons:
  - more state, possible over-tuning if too many thresholds
  - needs careful hysteresis to avoid thrashing
- Expected edge:
  - local 25-sim: 535-545 if tuned correctly; online likely lower but stable

## Approach B: Hazard-Based Carry/Harvest Controller
- Description:
  - estimate probability next event is same-step retail continuation vs next-step first-trade arb
  - solve one-step expected value to choose carry fee vs harvest rebate
- Pros:
  - theoretically aligned with event timing
  - can capture extra retail without losing protection
- Cons:
  - model error in hazard estimate can be expensive
  - can become fragile and unstable online
- Expected edge:
  - local 25-sim: 532-542

## Approach C: No-Arb-Band Midpoint Fair Filter + Control Barrier
- Description:
  - infer fair as midpoint of no-arb interval from previous quotes and observed spot
  - enforce control barrier for vulnerable side fee floor
- Pros:
  - mathematically elegant
  - explicit no-arb geometry
- Cons:
  - inference noise when market is not at boundary
  - prior tests showed collapse risk from estimator miscalibration
- Expected edge:
  - local 25-sim: 520-538 (higher tail, higher failure risk)

## Approach D: Quasi-Avellaneda Surface with Inventory PDE Approximation
- Description:
  - quote surface from sigma, inventory, and flow intensity via parametric approximation
- Pros:
  - principled market-making structure
- Cons:
  - too heavy/fragile for strict gas and sparse observability
  - likely insufficiently stable in this environment
- Expected edge:
  - local 25-sim: 525-538

## 4) Chosen Architecture and Why
- Selected **Approach A (Regime-Ladder + Toxicity FSM)**.

### Rationale
- It is structurally different from baseline single-lane heuristic updates.
- It directly addresses the key simulator asymmetry (first-trade arb risk vs later retail flow).
- It allows a stable defensive carry while still permitting measured undercut on safe side.
- It avoids fragile fair-estimation machinery that can trigger online instability.
- It is implementable within slot and gas constraints with clear rollback points.

## 5) Execution Plan
1. Measure restored baseline on local 25-sim and log it.
2. Implement minimal Regime-Ladder scaffolding (state score + hysteresis + base table).
3. Add toxicity FSM overlay and bounded shield mapping.
4. Add inventory skew and stabilization clamps.
5. Run 25-sim after each significant change and log before/after, failure modes, next step.
6. Revert any regression immediately.
7. Stop when either:
   - local 25-sim > 540, or
   - no meaningful architectural alternative remains and reasons are documented.

## Iteration 0 — Restored Baseline Measurement
- Change: restored `Strategy.sol` to last committed working baseline (`e9223e0`), no logic edits.
- Reason: online simulator reliability issue on newer variants; reset to known stable control.
- 25-sim score: **530.88**.
- Observed behavior:
  - Strong but below local 540 target.
  - Defensive profile remains heavy; likely leaves some retail share uncaptured in calm windows.
- Failure modes observed:
  - None (compiles and runs cleanly).
- Next iteration plan:
  - Implement a structurally different Regime-Ladder + Toxicity FSM architecture (Approach A).
  - Remove dependence on arb inversion fair estimate; replace with first-trade anchor and regime states.

## Iteration 1 — RegimeLadder v1 (Ground-Up) Attempt
- Change:
  - Replaced baseline with a full two-timescale architecture:
    - regime ladder from sigma/lambda
    - toxicity FSM
    - side shield around anchor
    - inventory skew
    - continuation harvesting logic
- Reason:
  - Structural redesign to separate slow regime inference from fast toxicity response.
- Score before: 530.88 (baseline)
- Score after: **N/A (failed)**
- Failure modes observed:
  - Runtime failure: **out of gas** during simulation.
  - Design too branch-heavy and compute-heavy for callback gas budget.
- Next iteration plan:
  - Keep the same architectural thesis but trim gas drastically:
    - remove nonessential branches (continuation harvest and heavy inventory path)
    - reduce slot writes
    - simplify regime update and toxicity transitions

## Iteration 2 — RegimeLadder v2 (Gas-Trimmed)
- Change:
  - Removed heavy branches from v1 to fit gas budget.
  - Kept regime ladder + toxicity FSM + anchor shield.
  - Dropped inventory-heavy path and simplified continuation logic.
- Reason:
  - Preserve new architecture while eliminating out-of-gas failure.
- Score before: 530.88 (baseline)
- Score after: **394.59**
- Where edge degraded:
  - Massive loss vs baseline indicates severe adverse-selection leakage and/or over-tight routing penalties.
  - Regime transitions likely too noisy; shield/rebate mapping too aggressive and misaligned.
- Failure modes observed:
  - No runtime failure, but economic failure (catastrophic underperformance).
- Action taken:
  - Marked as regression; will revert to baseline and try a different architecture path.
- Next iteration plan:
  - Try Hazard-Based Carry/Harvest controller (Approach B) with bounded asymmetry, starting from stable baseline mechanics.

## Reversion Check
- Reverted `Strategy.sol` to restored baseline snapshot.
- Verification run: **530.88** (25 sims), confirming clean rollback and no hidden drift.

## Iteration 3 — Hazard Carry/Harvest v1 (on Baseline Core)
- Change:
  - Added explicit `hazardBps` state:
    - increases on first-trade likely-arb events
    - decays over time
    - contributes to base carry fee
  - Replaced no-op continuation block with bounded continuation rebate tied to lambda,
    plus partial hazard re-arming.
  - Also used stronger baseline constants (`CORE=52`, `SAFE_REBATE=58`, `VOL_BUFFER_DIV=10`).
- Reason:
  - Test a distinct hazard-memory architecture for first-trade adverse selection.
- Score before: 530.88 (baseline)
- Score after: **511.76**
- Where edge degraded:
  - Continuation rebate logic likely over-discounted while still failing to prevent first-trade losses.
  - Hazard feedback added carry in wrong windows and reduced routing efficiency.
- Failure modes observed:
  - No runtime failure; pure economic regression.
- Action taken:
  - Regression logged; reverting to baseline.
- Next iteration plan:
  - Try a different structural path: explicit calibration-phase to lock sigma/lambda regime,
    with piecewise base-fee table and minimal extra state (avoid continuation discounting entirely).

## Reversion Check (after Iteration 3)
- Reverted to baseline snapshot again.
- Verification run: **530.88** (25 sims).

## Iteration 4 — Calibration-Lock Regime Table (minimal-state)
- Change:
  - Added calibration slots (`calibCount`, `sigmaLock`, `lambdaLock`, `calibDone`).
  - Used blended live/locked sigma and lambda control.
  - Added piecewise calm/storm adjustments for base fee and safe-side rebate.
  - Kept baseline execution path otherwise.
- Reason:
  - Test a low-gas structural shift: calibrate hidden regime then exploit.
- Score before: 530.88 (baseline)
- Score after: **530.50**
- Where edge degraded:
  - Mild but consistent loss; regime table likely over-constrains adaptation and reduces profitable routing windows.
- Failure modes observed:
  - No runtime/gas issues; pure slight economic regression.
- Action taken:
  - Regression logged; reverting to baseline.
- Next iteration plan:
  - Run one final meaningful architecture family: side-specific toxicity gate with asymmetric shock cooldown
    (stateful side defense but no calibration-lock).

## Reversion Check (after Iteration 4)
- Reverted to baseline snapshot.
- Verification run: **530.88** (25 sims).

## Iteration 5 — Side-Specific Cooldown Gates
- Change:
  - Added independent bid/ask cooldown states (`bidCoolBps`, `askCoolBps`) with decay.
  - Cooldowns increase on likely-arb side and large same-side prints.
  - Base quote starts from `base + sideCooldown`, preserving asymmetric defense.
  - Included stronger static envelope (`CORE=52`, `SAFE_REBATE=58`, `VOL_BUFFER_DIV=10`).
- Reason:
  - Test asymmetric toxic-flow gating without heavy calibration logic.
- Score before: 530.88 (baseline)
- Score after: **519.13**
- Where edge degraded:
  - Over-widening on active side appears to reduce routing share faster than arb protection gains.
  - Cooldown persistence likely misprices calm windows.
- Failure modes observed:
  - No runtime failure; economic regression.
- Action taken:
  - Regression logged; reverting to baseline.
- Next iteration plan:
  - Run broad but controlled search on stable baseline architecture constants to test if 540 is attainable
    without further structural regressions.

## Iteration 6 — Controlled Baseline Grid Search (25-sim)
- Change:
  - Reverted to stable baseline mechanics and performed full 25-sim grid search on key constants:
    - `CORE_BPS ∈ {48,52,56}`
    - `VOL_MULT_BPS ∈ {1300,1500,1700}`
    - `SAFE_SIDE_REBATE_BPS ∈ {42,58,70}`
    - `VOL_BUFFER_DIV ∈ {6,10}`
- Reason:
  - After multiple structural regressions, test reachability of 540 with stable execution path.
- Best result found:
  - **531.57** at:
    - `CORE_BPS=48`
    - `VOL_MULT_BPS=1300`
    - `SAFE_SIDE_REBATE_BPS=58`
    - `VOL_BUFFER_DIV=10`
- Key finding:
  - All tested `CORE_BPS >= 52` regions underperformed this local pack.
  - Best region remained tightly clustered around ~531-532, far below 540.
- Failure modes observed:
  - No runtime failures in the winning region.
  - Structural architecture variants repeatedly caused larger economic regressions than this tuned baseline.
- Action taken:
  - Set `Strategy.sol` to the best-found stable configuration (`531.57`).

## Final Status
- Target requested: **540+ local (25 sims)**.
- Achieved in this run: **531.57**.
- Conclusion: after multiple meaningful architectural alternatives + controlled grid search, no tested path crossed 540 without severe regression or instability. Current file is set to the strongest stable candidate discovered in this session.

## Final Verification Run
- Command: `./.venv313/bin/python -m amm_competition.cli run Strategy.sol --simulations 25`
- Result: **531.57**
- Final active constants in `Strategy.sol`:
  - `CORE_BPS=48`
  - `VOL_MULT_BPS=1300`
  - `SAFE_SIDE_REBATE_BPS=58`
  - `VOL_BUFFER_DIV=10`

## External Research Digest (Online References)

### A) AMM / Dynamic Fee / Adverse Selection Literature
- Uniswap v4 hooks and dynamic fees (hook-driven fee updates, keep logic lean and deterministic):
  - https://docs.uniswap.org/concepts/protocol/hooks
  - https://docs.uniswap.org/contracts/v4/concepts/hooks
- OpenZeppelin dynamic fee hook notes (permissionless fee updates and manipulation considerations):
  - https://docs.openzeppelin.com/uniswap-hooks/fee
- Uniswap Foundation v4 data article (dynamic LP fee and no persistent global fee tier constraint):
  - https://www.uniswapfoundation.org/blog/developer-guide-establishing-hook-data-standards-for-uniswap-v4
- LVR / AMM economics:
  - Milionis et al., *Automated Market Making and Loss-Versus-Rebalancing*:
    https://arxiv.org/pdf/2208.06046
  - Milionis et al., *Optimal Fees for Geometric Mean Market Makers*:
    https://arxiv.org/pdf/2305.14604
- Inventory-skew market making principle:
  - Avellaneda & Stoikov, *High-frequency trading in a limit order book*:
    https://math.nyu.edu/faculty/avellane/HighFrequencyTrading.pdf

### B) TradingView Popular Strategy Principles (Borrowable Components)
- ATR and volatility-regime filtering (volatility changes should alter aggressiveness):
  - https://www.tradingview.com/support/solutions/43000501823-average-true-range-atr/
- ADX trend-strength style filtering (not for direction, but for “market state intensity”):
  - https://www.tradingview.com/support/solutions/43000589099-average-directional-index-adx/
- Bollinger bandwidth / expansion-contraction regime framing:
  - https://www.tradingview.com/support/solutions/43000501840-bollinger-bands-bb/
- RSI-style bounded state oscillator idea (state machine bounded 0..100):
  - https://www.tradingview.com/support/solutions/43000502338-relative-strength-index-rsi/

### Mapped Design Implications for This Simulator
- LVR papers imply fee should respond to variance and informed-flow intensity; static fee leaves edge on table.
- Hook docs reinforce that profitable dynamic fee logic must remain simple, deterministic, low-overhead.
- TradingView volatility filters suggest robust regime detection should be based on volatility state, not direction prediction.
- Therefore, next architecture will:
  1. calibrate sigma + informed-flow intensity early,
  2. lock a regime anchor,
  3. dynamically blend lock/live estimates,
  4. apply bounded asymmetric shielding + inventory skew,
  5. avoid high-branch complexity that risks gas/reliability issues.

## Iteration 7 — Calibrated Informed-Flow Blend (online-research-inspired)
- Change:
  - Implemented a low-gas variant of lock/blend architecture using:
    - calibrated sigma/lambda/arb-intensity locks,
    - regime-conditioned base/rebate,
    - (initially) directional first-trade imbalance signal.
- Reason:
  - Apply LVR + dynamic-fee hook design principles with bounded regime adaptation.
- Result:
  - **Out of gas** even after trimming directional-imbalance layer.
- Failure modes observed:
  - Extra persistent state writes pushed callback over gas limit.
- Action taken:
  - Reverted to stable best-known baseline config.
  - Verified rollback score: **531.57** (25 sims).
- Next iteration plan:
  - Keep stable architecture fixed and run broader multi-parameter search over existing knobs only,
    since additional persistent-state architectures are not gas-feasible in this environment.

## Iteration 8 — Expanded Random Search on Stable Architecture
- Change:
  - Kept baseline mechanics fixed (no new persistent-state architecture).
  - Ran randomized multi-parameter search over 80 candidates (stage-1 at 10 sims), then top-12 validated at 25 sims.
  - Tuned dimensions included:
    - `CORE_BPS`, `VOL_MULT_BPS`, `SAFE_SIDE_REBATE_BPS`, `VOL_BUFFER_DIV`
    - `ARB_MAX_RATIO_WAD`, `FLOW_SWING_BPS`, `LOWLAM_SIGMA_WIDEN_BPS`, `ARMOR_MIN_BPS`
    - `TOX_UP_BPS`, `TOX_DOWN_BPS`, `INV_SENS_BPS`
- Best 25-sim result from this search:
  - **531.88** (new local best for this session)
  - Constants:
    - `CORE_BPS=48`
    - `VOL_MULT_BPS=1150`
    - `SAFE_SIDE_REBATE_BPS=50`
    - `VOL_BUFFER_DIV=10`
    - `ARB_MAX_RATIO_WAD=46*BPS`
    - `FLOW_SWING_BPS=6`
    - `LOWLAM_SIGMA_WIDEN_BPS=8`
    - `ARMOR_MIN_BPS=78`
    - `TOX_UP_BPS=4`
    - `TOX_DOWN_BPS=3`
    - `INV_SENS_BPS=201`
- Key finding:
  - Even with broader randomized exploration, top results remain in ~531-532 band.
  - No candidate crossed 540 on 25 sims.

## Updated Final Status
- Target requested: **540+ local (25 sims)**.
- Best achieved in this full run: **531.88**.
- Interpretation:
  - Additional architectural state appears gas-limited in this environment.
  - Within stable execution constraints, broad search still failed to find a 540+ configuration.
  - Current `Strategy.sol` is set to the strongest candidate found in this run.

## Iteration 9 — VolShield v1 (Ground-Up Volatility-Accumulator Rewrite)
- Change:
  - Replaced BandShield architecture with a new design inspired by LB/Meteora-style variable fees:
    - dynamic likely-arb classifier with fee-scaled size threshold,
    - volatility accumulator (`vacc`) with decay and convex fee surface,
    - side shield + inventory skew + bounded continuation rebate.
- Reason:
  - Attempt a genuinely different structural model rather than another baseline-parameter sweep.
- Score before: 531.88 (BandShield baseline, 25 sims)
- Quick validation score after rewrite: **396.66** (10 sims)
- Where edge degraded:
  - Severe adverse-selection leakage and/or routing loss indicates fee surface was miscalibrated to simulator dynamics.
  - Ground-up model diverged too far from proven carry-defense behavior.
- Failure modes observed:
  - No gas/runtime failure; pure economic collapse.
- Action taken:
  - Marked as regression and reverted immediately (per no-regression rule).
- Next iteration plan:
  - Keep the proven BandShield execution spine intact and introduce one structural innovation at a time (not full replacement), then re-evaluate.

## Reversion Check (after Iteration 9)
- Restored `Strategy.sol` to baseline (`BandShield_v4`) from `HEAD`.
- Verification runs:
  - 10 sims: **538.66**
  - 25 sims: **531.88**
- Baseline integrity confirmed before next architecture attempt.

## Iteration 10 — Contextual Continuation-Hazard Rebate (BandShield Spine)
- Change:
  - Kept BandShield core, added a new structural layer:
    - learned continuation probabilities (`contProbArb`, `contProbOther`) from observed same-timestamp follow-through,
    - context-aware carry rebate bounded by a volatility-linked carry floor.
- Reason:
  - Try to harvest same-step retail flow with explicit hazard modeling instead of fixed/no rebate.
- Scores (10 sims):
  - `CONT_REBATE_MAX_BPS=8`: **527.17**
  - `CONT_REBATE_MAX_BPS=3`: **527.28**
  - `CONT_REBATE_MAX_BPS=0`: **538.66** (back to baseline behavior)
- Where edge degraded:
  - Any nonzero continuation rebate materially worsened performance, implying next-step carry protection dominates continuation-harvest gains.
- Failure modes observed:
  - No gas/runtime failures; economic regression whenever rebate activated.
- Action taken:
  - Marked as failed architecture branch; reverted to baseline logic.
- Next iteration plan:
  - Test a different structural improvement: higher-precision arb-state inference (dynamic classification / fair-anchor quality) while preserving defensive carry.

## Iteration 11 — Fee-Aware, Side-Aligned Arb Classifier
- Change:
  - Replaced fixed arb-size threshold with a dynamic cap based on active side fee.
  - Added side-alignment gate (`trade.isBuy => spot >= pHat`, `trade.isSell => spot <= pHat`) for likely-arb filtering.
- Reason:
  - Improve fair-anchor update quality by reducing false arb classifications.
- Score before: baseline 538.66 (10 sims), 531.88 (25 sims)
- Score after: **517.04** (10 sims)
- Where edge degraded:
  - Classifier became too restrictive/misaligned, missing true arb updates and degrading fair/variance estimates.
- Failure modes observed:
  - No runtime failure; substantial economic regression.
- Action taken:
  - Reverted immediately to baseline.
- Next iteration plan:
  - Preserve baseline classifier and target a different structural axis (regime-conditioned safe-side rebate / shield geometry).

## Iteration 12 — Regime-Conditioned Shield Geometry
- Change:
  - Kept baseline architecture but changed side-shield mechanics structurally:
    - dynamic shield buffer (`sigma + shock + tox` based),
    - dynamic safe-side rebate with calm boost and stress cut,
    - explicit rebate caps.
- Reason:
  - Test whether adaptive routing/protection geometry beats fixed rebate under mixed regimes.
- Scores:
  - 10 sims: **538.37** (vs baseline 538.66)
  - 25 sims: **531.30** (vs baseline 531.88)
- Where edge degraded:
  - Adaptive rebate/buffer mapping likely overreacts in non-stress windows, modestly reducing capture.
- Failure modes observed:
  - No runtime failures; mild but consistent economic regression.
- Action taken:
  - Reverted to baseline.
- Next iteration plan:
  - Try a different architecture with explicit two-phase calibration lock (short learn window then mostly fixed regime policy) while keeping code/gas minimal.

## Iteration 13 — Side-Specific Toxicity Memory (Bid/Ask)
- Change:
  - Replaced single symmetric `tox` state with two directional states:
    - `bidTox` (pressure on AMM-buy side)
    - `askTox` (pressure on AMM-sell side)
  - Applied toxicity asymmetrically to base fees, while keeping shield/inventory logic.
- Reason:
  - Avoid wasting routing share by widening both sides when toxicity is directional.
- Score before: baseline 538.66 (10 sims)
- Score after: **531.88** (10 sims)
- Where edge degraded:
  - Side memory likely over-penalized active side relative to baseline shield, reducing capture without enough incremental protection.
- Failure modes observed:
  - No runtime failures; clear economic regression.
- Action taken:
  - Reverted to baseline.
- Next iteration plan:
  - Explore architecture that modulates base carry by explicit regime lock/calibration while leaving tactical layers unchanged.

## Iteration 14 — Event-Conditioned Safe-Side Rebate
- Change:
  - Kept baseline core but made safe-side rebate event-conditioned:
    - larger rebate after first-trade likely-arb,
    - reduced rebate after first-trade non-arb,
    - additional rebate cut under shock state.
- Reason:
  - Concentrate aggressive undercutting in windows where same-step retail continuation is most likely.
- Scores:
  - 10 sims: **537.92** (vs baseline 538.66)
  - 25 sims: **531.19** (vs baseline 531.88)
- Where edge degraded:
  - Conditional mapping appears to cut profitable safe-side capture more often than it helps.
- Failure modes observed:
  - No runtime failures; mild consistent regression.
- Action taken:
  - Reverted to baseline.
- Next iteration plan:
  - Explore a distinctly different structural idea with low state overhead: regime lock with one-way adaptive floor (calm unlock, storm lock).

## Iteration 15 — Expanded Deterministic Search on Stable BandShield Family
- Change:
  - Ran an expanded parameter search around the stable architecture using generated candidate files (no simulator code edits).
  - Search dimensions (16 knobs):
    - `CORE_BPS`, `VOL_MULT_BPS`, `BASE_MIN_BPS`, `FLOW_SWING_BPS`, `LOWLAM_SIGMA_WIDEN_BPS`
    - `ARMOR_MIN_BPS`, `SAFE_SIDE_REBATE_BPS`, `VOL_BUFFER_DIV`, `ARB_MAX_RATIO_WAD`
    - `TOX_UP_BPS`, `TOX_DOWN_BPS`, `TOX_BIG_UP_BPS`, `INV_SENS_BPS`
    - `SHOCK_BUMP_BPS`, `BIG_BUMP_BPS`, `ALPHA_SLOW`
  - Process:
    - Stage 1: 40 candidates on 10 sims
    - Stage 2: top 10 candidates on 25 sims
- Result:
  - Best candidate on 25 sims remained the baseline itself:
    - **531.88** (`idx=0`, baseline constants)
  - Best non-baseline 25-sim score observed: **531.85**.
- Key finding:
  - Higher 10-sim peaks (~539.1) did not translate to better 25-sim scores.
  - The deterministic 25-sim frontier in this architecture remains ~531-532.
- Artifacts:
  - Stage 1 CSV: `/var/folders/3n/7b4qqlzd49s3jd6fbh47nh0w0000gn/T/arch_search3.4ughftvb/stage1.csv`
  - Stage 2 CSV: `/var/folders/3n/7b4qqlzd49s3jd6fbh47nh0w0000gn/T/arch_search3.4ughftvb/stage2_25.csv`

## Current Best (Verified)
- Strategy file: `Strategy.sol` (BandShield_v4 baseline family)
- Verified score: **531.92** on 25 sims
- Verification command:
  - `./.venv313/bin/python -m amm_competition.cli run Strategy.sol --simulations 25`

## Iteration 16 — Direct 25-Sim Hill-Climb (Deterministic Objective)
- Change:
  - Ran simulated-annealing style hill-climb directly against the **25-sim** score (not 10-sim proxy), mutating 16 constants.
  - 36 deterministic iterations around baseline.
- Reason:
  - Final attempt to find a hidden local basin that proxy searches may miss.
- Outcome:
  - New best found: **531.92** (up from 531.88, +0.04)
  - Best config discovered:
    - `CORE_BPS=48`
    - `VOL_MULT_BPS=999`
    - `BASE_MIN_BPS=24`
    - `FLOW_SWING_BPS=6`
    - `LOWLAM_SIGMA_WIDEN_BPS=8`
    - `ARMOR_MIN_BPS=104`
    - `SAFE_SIDE_REBATE_BPS=49`
    - `VOL_BUFFER_DIV=9`
    - `ARB_MAX_RATIO_WAD=52*BPS`
    - `TOX_UP_BPS=5`
    - `TOX_DOWN_BPS=4`
    - `TOX_BIG_UP_BPS=5`
    - `INV_SENS_BPS=201`
    - `SHOCK_BUMP_BPS=10`
    - `BIG_BUMP_BPS=4`
    - `ALPHA_SLOW=79e16`
- Verification:
  - 25 sims: **531.92**
  - 500 sims: **516.14**

## Updated Best-In-Session Status
- Best local 25-sim achieved in this run: **531.92**
- Target 540+ remains unmet despite:
  - multiple architectural rewrites,
  - reversions on regressions,
  - expanded random search,
  - direct deterministic hill-climb.
