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

## Iteration 17 — Explicit Arb-Rate State (Informed Flow Probability)
- Change:
  - Added new state `arbRateEWMA` (first-trade likely-arb probability).
  - Used this state to:
    - increase/decrease base carry fee,
    - reduce safe-side rebate in high-toxicity windows.
- Reason:
  - Directly encode informed-vs-uninformed flow decomposition from first principles.
- Score before: 531.92 (25 sims)
- Quick check after change: **502.44** (10 sims)
- Where edge degraded:
  - Toxicity feedback appears too aggressive and destabilizes routing/carry balance.
  - Likely over-penalizes fees from a noisy classifier signal.
- Failure modes observed:
  - No runtime/gas failure; severe economic regression.
- Action taken:
  - Reverted immediately.
- Next iteration plan:
  - Keep best strategy state; continue with external-theory-driven architecture options that do not add high-gain feedback loops.

## Iteration 18 — First-Trade-Only Fair Recentering
- Change:
  - Modified fair-anchor recentering so `pHat` updates toward spot only on first trade of step when no arb print is observed.
  - Ignored continuation-trade spot recentering to reduce retail-noise contamination.
- Reason:
  - Improve fair-anchor quality by filtering out continuation retail prints.
- Score before: 531.92 (25 sims baseline)
- Quick check after change: **529.75** (10 sims)
- Where edge degraded:
  - Anchor became too stale in practice; reduced responsiveness outweighed noise reduction.
- Failure modes observed:
  - No runtime/gas failure; clear economic regression.
- Action taken:
  - Reverted immediately.

## Iteration 19 — InitialX-Anchored Inventory Skew (Avellaneda-Style q)
- Change:
  - Replaced fair-dependent inventory anchor (`xStar = sqrt(k/pHat)`) with fixed initial inventory anchor (`initialX`).
  - Inventory skew direction set by `(reserveX - initialX)` sign.
- Reason:
  - Remove fair-estimation noise from inventory control and align with textbook `q` formulation.
- Scores:
  - 10 sims: **536.53** (vs baseline 538.66)
  - 25 sims: **529.67** (vs baseline 531.92)
- Where edge degraded:
  - Fixed anchor appears less effective than fair-relative anchor in this simulator’s routing/arb dynamic.
- Failure modes observed:
  - No runtime failure; consistent economic regression.
- Action taken:
  - Reverted immediately.

## Iteration 20 — Convex Volatility Pulse Surcharge (LB-Inspired)
- Change:
  - Added a dedicated `pulseBps` accumulator with decay and convex fee surcharge:
    - pulse increases on likely-arb implied returns,
    - pulse decays when no arb print,
    - base fee receives linear + quadratic pulse add-on.
- Reason:
  - Import Liquidity Book style variable-fee behavior into the stable strategy with minimal additional state.
- Score before: 531.92 (25 sims baseline)
- Quick check after change: **518.34** (10 sims)
- Where edge degraded:
  - Added pulse made quotes too defensive and likely reduced routing share more than it saved on arb.
- Failure modes observed:
  - No runtime failure; strong economic regression.
- Action taken:
  - Reverted immediately.

## External Research Update (This Iteration)

### Primary Sources Reviewed
- Uniswap v4 dynamic-fee / hooks docs:
  - https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees
  - https://docs.uniswap.org/contracts/v4/reference/periphery/utils/BaseHook
- Uniswap v4 hooks concepts:
  - https://docs.uniswap.org/concepts/protocol/hooks
- Orca Whirlpools adaptive fee (volatility-accumulator style):
  - https://docs.orca.so/whirlpools/fees
- Pancake Infinity dynamic LP fee mechanism:
  - https://docs.pancakeswap.finance/trade/pancakeswap-infinity/hooks/hook-types/dynamic-lp-fee-hook
- LVR / optimal fee papers:
  - https://arxiv.org/pdf/2208.06046
  - https://arxiv.org/pdf/2305.14604
- Avellaneda–Stoikov inventory/skew framework:
  - https://math.nyu.edu/faculty/avellane/HighFrequencyTrading.pdf
- Trader Joe / Liquidity Book variable fee reference (formula excerpt):
  - https://github.com/lfj-gg/joe-v2/blob/main/src/LBPair.sol
  - https://github.com/traderjoe-xyz/LB-Whitepaper/blob/main/Joe%20v2%20Liquidity%20Book%20Whitepaper.pdf

### First-Principles Takeaways
- Dynamic-fee AMMs in production generally combine:
  1. volatility accumulator,
  2. decay windows,
  3. convex surcharge for burst protection,
  4. bounded floors/caps to preserve routing.
- In this competition environment, carry protection for next-step first-trade arb dominates aggressive same-step retail harvesting.
- High-gain feedback loops (toxicity->fee->routing->toxicity) are very easy to destabilize under strict observability/gas limits.
- The robust frontier in this simulator appears to favor stable side-shield mechanics with conservative state complexity.

### Research-Driven Branches Tested in This Iteration
- Explicit informed-flow probability (`arbRate`) state:
  - severe regression (10-sim 502.44), reverted.
- First-trade-only fair recentering:
  - regression (10-sim 529.75), reverted.
- InitialX-anchored inventory skew (pure Avellaneda q):
  - regression (25-sim 529.67), reverted.
- LB-style convex volatility pulse surcharge:
  - regression (10-sim 518.34), reverted.

### Conclusion From This Research Cycle
- The best retained strategy remains the tuned BandShield variant at **531.92 (25 sims)**.
- Breaking beyond this likely requires a genuinely different but still gas-safe policy class; current straightforward imports of production dynamic-fee mechanisms underperform in this simulator when grafted directly.

## Iteration 21 — Auction Clock Carry Premium
- Change:
  - Added bounded sigma-scaled carry premium on quote publication (`+1..6 bps`, proportional to sigma) to harden between-step first-trade exposure.
- Reason:
  - Test deterministic first-trade protection mechanism from event-order structure.
- Scores:
  - 10 sims: **534.22** (vs 538.48 baseline)
  - 25 sims: **527.31** (vs 531.92 baseline)
- Where edge degraded:
  - Premium appears to leak too much same-step routing share versus incremental arb protection.
- Failure modes observed:
  - No runtime failure; clear economic regression.
- Action taken:
  - Reverted immediately.

## Iteration 22 — Time Machine + Entropy Gauge Stack
- Change:
  - Added phase-aware multipliers (recon/endgame) for base fee and safe-side rebate.
  - Added entropy gauge (`slot[14]` arb observation count) with uncertainty premium `~1/sqrt(N)`.
- Reason:
  - Test low-gas first-principles regime/uncertainty controls.
- Scores:
  - Time Machine only: 10 sims **538.48**, 25 sims **531.82**
  - Time Machine + Entropy: 10 sims **538.47**, 25 sims **531.81**
- Where edge degraded:
  - Both variants were near-neutral to slightly negative; no measurable improvement over baseline 531.92.
- Failure modes observed:
  - No runtime/gas issues.
- Action taken:
  - Reverted to baseline before testing other mechanisms.

## Iteration 23 — Weather-Adaptive Safe-Side Rebate
- Change:
  - Replaced fixed safe-side rebate with dynamic rebate driven by sigma, lambda, and stress/shock cuts.
- Reason:
  - Test regime-aware routing capture (larger rebate in calm/busy, smaller in storm/sparse).
- Scores:
  - 10 sims: **532.11**
  - 25 sims: **525.63**
- Where edge degraded:
  - Dynamic rebate was too aggressive/variable and significantly harmed routing/protection balance.
- Failure modes observed:
  - No runtime/gas issues; major economic regression.
- Action taken:
  - Reverted immediately.

## Iteration 24 — Directional Toxicity + Calculus Blend
- Change A (Directional Tox only):
  - Removed symmetric `+tox` in base and applied heavier toxicity on the active side (133% / 75% split by side+streak).
  - Score:
    - 10 sims: **538.48**
    - 25 sims: **531.91**
  - Net: essentially neutral vs 531.92 baseline.

- Change B (add Calculus Blend on top):
  - Added bounded optimal-fee proxy `~ sigma/sqrt(lambda)` blended 90/10 with heuristic base.
  - Score:
    - 10 sims: **538.27**
    - 25 sims: **531.42**
  - Net: regression.

- Failure modes observed:
  - No runtime/gas issues.
- Action taken:
  - Reverted this branch and returned to baseline before next architecture test.

## Iteration 25 — Bayesian/Continuous Arb Probability Engine
- Change:
  - Replaced binary `likelyArb` classification with posterior-like `arbProb` from:
    - first-trade prior,
    - size signal (vs arb-size cap),
    - direction alignment (spot vs pHat).
  - Used `arbProb` to blend fair target (`pEst` vs spot), variance alpha, and toxicity deltas.
- Reason:
  - Test continuous-probability updates to avoid hard-threshold misclassification cliffs.
- Quick score:
  - 10 sims: **523.28**
- Where edge degraded:
  - Probability blend was miscalibrated for this environment and significantly degraded fair/tox update quality.
- Failure modes observed:
  - No runtime failure; strong economic regression.
- Action taken:
  - Reverted immediately.

## Iteration 26 — Direct 25-Sim Hill-Climb (New Best)
- Change:
  - Ran another direct 25-sim objective hill-climb from the current best baseline.
  - 40 iterations, multi-parameter mutation over 16 constants.
- New best found:
  - **532.10** (improved from 531.92)
  - Constants:
    - `CORE_BPS=46`
    - `VOL_MULT_BPS=1031`
    - `BASE_MIN_BPS=22`
    - `FLOW_SWING_BPS=3`
    - `LOWLAM_SIGMA_WIDEN_BPS=7`
    - `ARMOR_MIN_BPS=112`
    - `SAFE_SIDE_REBATE_BPS=45`
    - `VOL_BUFFER_DIV=7`
    - `ARB_MAX_RATIO_WAD=49*BPS`
    - `TOX_UP_BPS=4`
    - `TOX_DOWN_BPS=1`
    - `TOX_BIG_UP_BPS=3`
    - `INV_SENS_BPS=294`
    - `SHOCK_BUMP_BPS=9`
    - `BIG_BUMP_BPS=4`
    - `ALPHA_SLOW=82e16`
- Verification:
  - 25 sims: **532.10**
  - 500 sims: **516.25**
- Notes:
  - This is a modest but real deterministic improvement over prior best.

## Updated Current Best
- Strategy file: `Strategy.sol`
- Best verified local scores in this run:
  - 25 sims: **532.10**
  - 500 sims: **516.25**

## Iteration 27 — Hard-Fork Branch: Shadow Normalizer Mirror + Regret Floor
- Change:
  - Implemented a new policy class with:
    - shadow normalizer reserves (`shadowX`, `shadowY`) and routing-share EWMA (`rhoEWMA`),
    - mirror-based base/rebate feedback toward regime-dependent routing-share targets,
    - regret-biased uncertainty floor using arb observation count (`arbObsCount`, `1/sqrt(N)` premium).
- Initial score (un-tuned hard-fork):
  - 10 sims: **538.74**
  - 25 sims: **531.98**
- Tuning run:
  - 24-candidate direct 25-sim sweep over mirror/regret constants only.
  - Best tuned hard-fork candidate: **532.08**
  - Best tuned params (hard-fork branch):
    - `ALPHA_RHO=16e16`
    - `RHO_TARGET_CALM=58e16`
    - `RHO_TARGET_MID=57e16`
    - `RHO_TARGET_STORM=50e16`
    - `RHO_SHIFT_MAX_BPS=1`
    - `RHO_REBATE_MAX_BPS=5`
    - `SHADOW_RETAIL_DAMP=82e16`
    - `SAFE_REBATE_MIN_BPS=21`
    - `SAFE_REBATE_MAX_BPS=75`
    - `REGRET_UNCERT_K_X10=67`
    - `REGRET_UNCERT_MAX_BPS=5`
- Result:
  - Hard-fork branch did not beat current best non-mirror strategy (532.10).
- Action:
  - Revert to the best known strategy configuration (Iteration 26 constants).

## Reversion Check (after Iteration 27)
- Restored best known non-mirror strategy constants (Iteration 26 set).
- Verification:
  - 10 sims: **538.99**
  - 25 sims: **532.10**

## Iteration 28 — Moon26 Full Rewrite (collapsed)
- Change:
  - Replaced baseline with a full 26-slot rewrite (`BandShield_Moon26b`) including:
    - fast/slow fair anchors,
    - fast/slow sigma,
    - fast/slow lambda,
    - hazard state machine,
    - PI control,
    - dynamic rebates + carry premium.
- Scores:
  - 10 sims: **399.04**
  - 25 sims: **410.60**
- Failure mode:
  - Severe routing-share collapse from over-defensive control stack.
- Action:
  - Abandoned full rewrite, reverted to baseline-anchored approach.

## Iteration 29 — Baseline-Anchored Moon26 Scaffold
- Change:
  - Rebuilt as `BandShield_Moon26c`: preserved BandShield v4 economics, then layered bounded multi-timescale/hazard/PI state.
  - Disabled harmful offside gate and restored baseline rebate behavior.
- Scores (stabilized scaffold):
  - 10 sims: **538.47**
  - 25 sims: **531.79**
- Outcome:
  - Recovered baseline neighborhood without regression blowup.

## Iteration 30 — 40-Candidate 10-Sim Constant Search on Moon26c
- Change:
  - Randomized 23 constants around the stabilized scaffold (core fee, vol scaling, rebate, inventory, tox, smoothing, weak hazard/PI knobs).
- Best candidate found:
  - 10 sims: **538.90**
  - 25 sims: **531.74**
- Failure mode:
  - Strong local ceiling at ~538–539 on 10 sims; no breakout signal.

## Iteration 31 — Structural A/B (Offside/Hazard/PI/Sigma Blend)
- A/B matrix results (10 sims):
  - neutral: **538.90**
  - mode_mild (hazard carry active, offside disabled): **539.00**
  - mode_offside: **497.96**
  - mode_offside_pi: **496.33**
  - offside_only: **519.85**
  - pi_only: **536.41**
  - sigma_blend: **538.82**
  - mode_sigma_blend: **538.91**
  - full_stack: **494.83**
- Conclusion:
  - Offside-gating remains strongly harmful in this simulator.
  - Mild hazard carry is slightly positive but not a breakthrough.

## Iteration 32 — Focused Hazard/Carry Sweep (60 candidates)
- Change:
  - Searched active hazard regime parameters only (ON/OFF hysteresis, hazard increments, carry add, carry rebate, comp cut, low-gain PI).
- Best candidate:
  - 10 sims: **539.24**
  - 25 sims: **532.00**
- Outcome:
  - Tiny gain vs 531.92 baseline, still below established best 532.10.
  - Ceiling persists in high-530s for this branch.

## Reversion to Current Best (no regression shipped)
- Action:
  - Restored the known best BandShield v4 constant set from Iteration 26.
- Verification:
  - 10 sims: **538.99**
  - 25 sims: **532.10**
  - 100 sims: **522.37**
  - 500 sims: **516.25**
- Note:
  - 560+ on 10 sims was not achieved in this cycle despite full rewrite + structural sweeps.
  - No Rust/Python simulator files were modified.

## External Research Synthesis (This Cycle)
Sources reviewed and mapped into strategy design:
- Milionis et al., *Automated Market Making and Loss-Versus-Rebalancing* (arXiv:2208.06046, revised May 27, 2024).
  - Key takeaway used: informed-flow pickoff (LVR) is the dominant LP drag; protecting first-print stale-price exposure matters more than generic fee volatility.
- Baggiani et al., *Optimal Dynamic Fees in Automated Market Makers* (arXiv:2506.02869, June 24, 2025).
  - Key takeaway used: two-fee-regime structure (defensive vs flow-seeking) and linear-in-inventory / external-price-sensitive approximations are theoretically justified.
- Uniswap v4 hooks documentation (official docs + hook guides).
  - Key takeaway used: dynamic-fee architecture is naturally event-driven and should remain low-latency and bounded to avoid control-loop instability.
- Meteora DLMM dynamic fee docs.
  - Key takeaway used: variable fee linked to volatility accumulator (quadratic pressure under stress) supports hazard bumping in high-vol/low-flow windows.

How this informed experiments:
- Tried explicit defensive/competitive regime machine (hazard carry), PI-style flow control, and stronger mispricing gates.
- Empirical result in this simulator: offside/mispricing gates were consistently too punitive to routing share; mild hazard carry helped only marginally.
- Net outcome: theoretical controls are valid conceptually, but current simulator reward surface heavily favors the calibrated BandShield-v4 style compromise over aggressive regime switching.

## Iteration 33 — Post-BandShield_v4 Breakout Push (Current Cycle)

### Objective
- Push past the ~540 10-sim plateau, with hard target 550+.
- Keep simulator code untouched; strategy-only iterations.

### What Changed
- Ran multiple architectural branches and large randomized sweeps:
  - `Strategy_alt3` (hazard + confidence-scaled rebate + dynamic arb cap)
  - `Strategy_clock` (auction-clock carry/rearm idea)
  - `Strategy_alt2` wide/focused/random/hill sweeps
  - `Strategy_phase2` (light 3-phase overlay)
  - `Strategy_alt5` (adaptive arb-classification threshold via trade-ratio EWMA + sigma)
- Added deterministic sensitivity checks (single-parameter and grid sweeps) to identify the strongest levers before broad searches.

### Key Findings
- **Strongest single lever this cycle:** arb classification width.
  - Baseline `ARB_MAX_RATIO_WAD=40bps` scored 540.76 (10 sims).
  - `ARB_MAX_RATIO_WAD=58bps` raised to 541.56.
- Hazard/confidence branch improved but stayed in low 541s.
- Auction-clock carry/rearm branch regressed severely (~516 on 10 sims).
- Time-phase overlay was near-neutral/slightly positive on 10 sims, negative on 25 sims.
- New adaptive classifier branch (`alt5`) produced the best verified result in this cycle.

### Best Verified Candidate (Current)
- File architecture now in `Strategy.sol` (from `Strategy_alt5`):
  - Adaptive arb cap:
    - `arbCap = ARB_BASE + ratioEWMA/ARB_RATIO_DIV + sigma/ARB_SIGMA_DIV`, capped.
  - Maintains profitable asymmetry spine (shield + x* inventory + shocks + smoothing).
- Scores:
  - **10 sims: 542.16**
  - **25 sims: 535.01**
- This is the highest deterministic 10-sim score achieved in this cycle, but still below 550.

### Failure Modes Observed
- Heavy offside/mispricing gating still harms routing share too much.
- Over-defensive carry-first systems collapse flow and underperform.
- Large architectural forks remain fragile under gas/stack constraints.

### External Research Applied This Cycle
- Re-checked dynamic-fee principles from:
  - Uniswap v4 dynamic fees docs (hook-driven event updates)
  - Meteora dynamic fee docs (volatility-linked fee pressure)
  - LVR / optimal dynamic-fee papers already in earlier iterations
- Translation into this simulator:
  - Keep latency-light fee updates.
  - Emphasize informed-flow classification quality over extra control complexity.

### Next Iteration Plan
1. Continue from `Strategy.sol` (alt5 spine) with focused coordinate descent only (not broad random).
2. Add low-cost direction-consistency weighting to arb classification (probabilistic, not hard gate).
3. Add minimal uncertainty premium from arb-observation count without adding offside gate complexity.
4. Re-validate at 10/25/100 after each structural change.

## Iteration 34 — Plateau Breakout Attempt (Moonshot + Broad Search)

### Objective
- Hard push for 550+ on local 10 sims using architecture-level changes, then broad parameter search.
- Constraint respected: strategy-only edits (no Rust/Python simulator file edits).

### Baseline at Start
- Working baseline: `Strategy.sol` (direction-aware arb classifier)
- Verified start score:
  - 10 sims: **546.24**

### Branch A — Full 26-slot Moonshot (multi-timescale + hazard + PI)
- Change:
  - Built a ground-up 22+ slot design with:
    - fast/slow fair + variance + lambda,
    - hazard EWMA with hysteresis mode switching,
    - PI-style lambda targeting,
    - directional streak overlays.
- Result:
  - **Failed runtime with Out-of-Gas** on simulator.
- Failure mode:
  - Control richness exceeded practical gas/runtime limits.
- Action:
  - Discarded branch.

### Branch B — Lightweight Hazard Regime on Winner Spine
- Change:
  - Added compact hazard slot and mode-like defensive floor shaping to baseline.
- Result:
  - 10 sims around **546.42–546.44** after tuning.
- Failure mode:
  - Flat response surface; no breakout despite multiple sweeps.
- Action:
  - Kept as reference, not final.

### Branch C — Volatility Accumulator (LFJ/Meteora-inspired)
- Change:
  - Added decaying volatility accumulator with quadratic fee pressure (`volAcc^2` term).
- Result:
  - Initial config: **533.56** (10 sims)
  - Softened config: **542.31** (10 sims)
- Failure mode:
  - Over-defensive convex term overcharged and reduced routing share.
- Action:
  - Discarded branch.

### Branch D — Continuous Arb-Probability Weighting (Bayesian-lite)
- Change:
  - Replaced hard arb classification with weighted arb probability for pHat/var/lambda updates.
- Result:
  - **543.87** (10 sims)
- Failure mode:
  - Smearing arb inference degraded fair anchor precision vs hard-gated classifier.
- Action:
  - Discarded branch.

### Branch E — Dual-timescale Sigma (Low-cost Structural Add)
- Change:
  - Added slow variance state + blended sigma.
  - Moved lambda update to non-arb first-in-step prints only.
  - Tuned arb cap + vuln buffer around this branch.
- Best verified configuration:
  - `ARB_BASE_RATIO_WAD = 19 * BPS`
  - `ARB_SIGMA_DIV = 7`
  - `VULN_BUFFER_BPS = 0`
  - plus dual-sigma blend from `Strategy_alt15`.
- Score:
  - **10 sims: 546.64**
  - **25 sims: 538.98**

### Broad Search Runs (completed in this cycle)
- Focused grids on strongest levers (`ARB_BASE`, `ARB_SIGMA_DIV`, `VULN_BUFFER`, rebate knobs):
  - Best observed from focused grid: **546.64** (10 sims).
- Randomized 40-candidate search over 20+ constants (3-sim screen, top-10 on 10 sims):
  - Best validated: **544.98** (10 sims), below champion candidate.

### External Research Applied in This Cycle
- Uniswap v4 whitepaper / docs (dynamic fees via hooks, bounded event-driven controls).
- LFJ (Trader Joe Liquidity Book) dynamic fee docs (volatility accumulator + quadratic variable fee term).
- LVR literature context (loss-vs-rebalancing scaling and informed-flow protection).
- Empirical takeaway for this simulator:
  - Aggressive control stacks and convex fee modules underperform unless very tightly constrained.
  - Precision arb classification + low-gas asymmetry remains the dominant edge driver.

### Net Outcome
- Target `555` on 10 sims **not reached** in this cycle.
- New local best in this cycle:
  - **546.64 (10 sims)**
  - **538.98 (25 sims)**
- `Strategy.sol` updated to this best verified candidate.

## Iteration 35 — Final Promotion + Stability Validation

### Promoted Strategy
- Promoted the best candidate from this cycle into `Strategy.sol`:
  - Based on dual-timescale variance blend branch (`alt15`), with tuned constants:
    - `ARB_BASE_RATIO_WAD = 19 * BPS`
    - `ARB_SIGMA_DIV = 7`
    - `VULN_BUFFER_BPS = 0`
  - Plus:
    - slow variance state (`varSlow`) blended with fast variance for sigma,
    - lambda update restricted to non-arb first-in-step events.

### Verified Scores (promoted `Strategy.sol`)
- 10 sims: **546.64**
- 25 sims: **538.98**
- 100 sims: **529.28**
- 500 sims: **522.63**

### Delta vs prior best baseline neighborhood
- 10 sims: +0.40 vs 546.24
- 25 sims: +0.20 vs 538.78 (prior local best in this branch family)
- 500 sims: materially higher than earlier 516.x class runs from prior cycles.

### Outcome
- Hard 555 target on local 10-sim still not reached.
- Kept the highest-performing and most stable candidate found in this run.

## Iteration 36 — Online Failure Root Cause + Deploy-Safe Frontier Reset

### Root Cause (online "Stream ended without completion")
- Diagnosed by forcing local deploy gas limits on candidate bytecode.
- Finding: strategies around ~4.8KB+ creation bytecode failed at `1,000,000` deploy gas despite passing validation/compilation.
- This exactly matches the online symptom: validation passes, simulation stream dies immediately.

### Evidence
- `Strategy_align_mix_best.sol` (creation ~4911 bytes): fails deploy at 1.0M, succeeds ~1.15M.
- `Strategy_alt12_localbest.sol` (creation ~4892 bytes): fails at 1.0M, succeeds ~1.15M.
- Deploy-safe branch around 4.2KB–4.4KB creation bytecode deploys reliably at 1.0M.

### Action
- Kept strategy work inside deploy-safe bytecode envelope while optimizing edge.

## Iteration 37 — Deploy-Safe Branch Promotion and Broad Bench

### Baseline Promotion
- Promoted compact align-lite branch into `Strategy.sol`:
  - score: **547.10 (10 sims)**
  - deploy-safe at 1.0M

### Full Local Variant Sweep
- Benchmarked all local `Strategy*.sol` files at 10 sims.
- Best raw local score found in repo: `Strategy_align_mix_best.sol` at **547.10**, but not deploy-safe.
- Best deploy-safe family remained the compact align-lite around **546.59–547.10**.

## Iteration 38 — Structural Tries (Rejected)

Tried and reverted after regressions:
- Directional toxicity memory (extra slot):
  - 10 sims ~**546.74** (regressed)
  - also increased size enough to fail 1.0M in one configuration.
- Lambda-adaptive arb-cap modifier:
  - 10 sims ~**543.93** (major regression)
  - deploy 1.0M fail in tested config.
- Hazard-on-arb state bump:
  - 10 sims ~**542.03** (major regression), deploy fail.
- Directional streak fee bump:
  - 10 sims ~**546.12** (regression), deploy-safe but rejected.
- Asymmetric continuation rebate after likely-arb first print:
  - 10 sims ~**545.63** (regression), rejected.

Conclusion: these added controls over-defend and lose routing share in this simulator.

## Iteration 39 — Compact Nonlinear Lambda Form (Kept)

### Change
- Replaced piecewise lambda tightening/widening block with compact nonlinear scaling:
  - `safeBps = safeBps * (LAMBDA_REF + ARMOR_LAMBDA) / (lambdaEWMA + ARMOR_LAMBDA)`

### Result
- Edge unchanged vs prior best neighborhood (to 2 decimals), but bytecode dropped materially.
- This created extra bytecode headroom for further tests while keeping behavior stable.

## Iteration 40 — Phase Overlay Refinement + Local Interaction Search

### Phase overlay tuning
- Added and tuned lightweight 3-phase additives (recon/endgame).
- Best tuned set:
  - `RECON_END_TS = 188`
  - `RECON_SAFE_ADD_BPS = 2`
  - `RECON_VULN_ADD_BPS = 10`
  - `ENDGAME_START_TS = 9681`
  - `END_SAFE_ADD_BPS = 3`
  - `END_VULN_ADD_BPS = 7`

### 1D + interaction sweeps
- Single and pairwise sweeps found small positive moves in:
  - `ARB_SIGMA_DIV = 10`
  - `INV_SENS_BPS = 132`
  - `SHOCK_RATIO_WAD = 96 * BPS`

### Promoted constants
- `ARB_SIGMA_DIV = 10`
- `INV_SENS_BPS = 132`
- `SHOCK_RATIO_WAD = 96 * BPS`
- plus phase constants above.

### Final verified scores (current `Strategy.sol`)
- **10 sims: 547.21**
- **25 sims: 539.25**
- **99 sims: 529.44**
- Creation bytecode size: **4147**
- Deploy at 1.0M gas: **PASS**

## Current Ceiling Assessment
- Despite multiple structural additions and extensive tuning, this deploy-safe architecture family is currently plateauing around **547.2** on deterministic 10-sim local seeds.
- The hard 555 local target was not reached in this cycle.
- Most high-control mechanisms (hazard/offside/toxicity stacks) consistently regress due routing-share loss.

## Next High-Conviction Path
1. Build a second compact family centered on cleaner arb probability estimation (continuous weight, but very lightweight) without hazard/offside stacks.
2. Keep bytecode under ~4.35KB to preserve online deploy reliability.
3. Run multi-stage search (3 -> 10 -> 25 sims) only on two strongest families to avoid search dilution.

## Iteration 41 — Long-Horizon Pivot (online-gap response)

### Trigger
- User reported online 1000-sim score ~514.47 while local short-horizon remained higher.
- Interpreted as robustness/generalization gap, not validator failure.

### Approach
- Switched optimization objective from 10-sim peak to long-horizon stability (99/500 proxies).
- Preserved deploy safety at 1,000,000 gas as a hard constraint.

### Structural change introduced
- Added stale-aware `pHat` recentering with `lastArbTs`:
  - On non-arb trades, recenter alpha increases with time since last arb event.
  - Rationale: reduce stale-fair drift risk in long no-arb intervals (tail loss control).
- Kept the nonlinear lambda scaling block (compact form) due same-or-better score with smaller bytecode.

### Intermediate outcomes
- Initial stale-aware variant:
  - 10: 546.52
  - 25: 539.13
  - 99: 529.50
  - 500: 522.98
- Combined stale-aware + robust constant cluster briefly improved 99 but exceeded deploy gas (>1.0M).
- Removed explicit recon/endgame branch code (not just constants), recovering deploy safety and improving robustness.

## Iteration 42 — Robustness Search (50/99/500)

### Search framework
- Random and targeted sweeps with objective priority:
  - 99-sim first, then 500-sim confirmation.
- Kept bytecode under deploy-safe envelope; rejected any candidate failing 1.0M deploy.

### What moved the needle
- Better long-run performance came from:
  - faster stale recenter adaptation,
  - slightly wider shock trigger threshold,
  - moderate inventory sensitivity,
  - moderate arb-side continuation rebate.

### Final promoted constants
- `ARB_SIGMA_DIV = 9`
- `SAFE_VOL_MULT_BPS = 2400`
- `INV_SENS_BPS = 128`
- `SHOCK_RATIO_WAD = 106 * BPS`
- `CONT_ARB_REBATE_BPS = 5`
- `PHAT_RECENTER_BASE = 4e16`
- `PHAT_RECENTER_PER_STEP = 16e14`
- `PHAT_RECENTER_MAX = 20e16`
- Other robust constants retained from prior branch.

### Final verified metrics (`Strategy.sol`)
- 10 sims: **546.91**
- 25 sims: **539.67**
- 99 sims: **529.85**
- 500 sims: **523.25**
- Creation bytecode: **4156**
- Deploy at 1.0M gas: **PASS**

### Delta vs previous promoted baseline
- Previous promoted (before this robustness pivot):
  - 10: 547.21
  - 25: 539.25
  - 99: 529.36
  - 500: 522.78
- New:
  - 10: 546.91 (**-0.30**)
  - 25: 539.67 (**+0.42**)
  - 99: 529.85 (**+0.49**)
  - 500: 523.25 (**+0.47**)

Interpretation: short-horizon peak reduced modestly while long-horizon robustness improved consistently.

## External Research Applied (this cycle)
- Uniswap v4 dynamic fees docs / whitepaper: hook-driven per-swap fee adaptation and bounded control loops.
- Meteora DLMM fee model: volatility-linked fee adaptation with accumulator-style behavior.
- Orca adaptive fee docs: adaptive fee updates tied to observed volatility proxies.
- Aave V3.1 governance interest-rate model discussion: kinked/defensive pricing under stress (inspired convex defense thought process).
- Morpho AdaptiveCurveIRM blog: state-aware dynamic pricing with stability-vs-responsiveness tradeoff.

### Practical takeaway from sources in this simulator
- Heavy multi-controller stacks often over-defend and lose routing share.
- Best improvements came from compact stateful defenses that specifically reduce stale-price tail losses while keeping fee responsiveness bounded.

## Iteration 43 — Final Robustness Consolidation

### Structural retention
- Kept stale-aware pHat recenter module (`lastArbTs` + adaptive recenter alpha).
- Kept compact nonlinear lambda scaling block.
- Removed explicit recon/endgame branch logic (bytecode + robustness win).

### Focused tuning (long-horizon objective)
- Used 99/500 as primary objective, with deploy safety constraint preserved.
- Tuned recenter response and shock/inventory/arb-classification knobs.

### Final selected settings (from coordinate + combo search)
- `ARB_SIGMA_DIV = 9`
- `SAFE_VOL_MULT_BPS = 2400`
- `INV_SENS_BPS = 128`
- `SHOCK_RATIO_WAD = 106 * BPS`
- `CONT_ARB_REBATE_BPS = 5`
- `PHAT_RECENTER_BASE = 4e16`
- `PHAT_RECENTER_PER_STEP = 16e14`
- `PHAT_RECENTER_MAX = 20e16`

### Rejected in this pass
- Soft offside/kink additive bump on safe side (mispricing-based):
  - worsened 10/25/99 and was reverted.

### Final verification (current `Strategy.sol`)
- 10 sims: **546.91**
- 25 sims: **539.67**
- 99 sims: **529.85**
- 500 sims: **523.25**
- Bytecode size: **4156**
- Deploy gas @ 1,000,000: **PASS**

### Net effect vs pre-pivot baseline
- Improved robustness objectives while preserving online deploy safety:
  - 25: +0.42
  - 99: +0.49
  - 500: +0.47
- Small tradeoff in 10-sim peak (-0.30), consistent with reduced overfitting.

## Iteration 44 — QCSC Ground-Up Rewrite (theory-first carry/continuation)

### Change
- Replaced `Strategy.sol` with a fresh architecture implementing:
  - continuation competition quote,
  - carry premium blended by continuation probability,
  - hazard state + uncertainty premium,
  - dynamic weather rebate.

### Result
- 10 sims: **529.49** (major regression).

### Diagnosis
- The full rewrite discarded too many calibrated priors from the robust baseline.
- Carry/continuation blend and hazard constants were materially miscalibrated.
- This was a structural miss, not a compile/runtime issue.

### Action
- Reverted to robust baseline (`Strategy_coord99_best.sol`).

## Iteration 45 — Baseline Random Constant Search (36 candidates)

### Change
- Randomized key baseline constants (vol slope, vulnerable floor/divider, inventory skew, continuation rebates, shock, recenter, smoothing).

### Result
- Best candidate: **546.62** (10 sims), below baseline **546.91**.

### Diagnosis
- Current robust constant set remains near local optimum in this family.
- Broad random perturbations mostly regress into 542–546 band.

## Iteration 46 — Uncertainty Gauge on Baseline Spine

### Change
- Added arb observation count + uncertainty premium in safe/vulnerable fees.
- Tried confidence-scaled continuation rebates.

### Results
- Initial compile issue (`viaIR` stack too deep), simplified implementation.
- Simplified variant: **546.81** (10 sims), slight regression.
- Sweep over uncertainty params (`k`, cap): best = **546.91** at `k=0` (module effectively disabled).

### Diagnosis
- In this environment, this uncertainty overlay did not add value beyond existing stale-aware recenter + shield.

### Action
- Reverted to baseline.

## Iteration 47 — Full Strategy Library Benchmark (all local variants)

### Change
- Ran 10-sim benchmark for all `Strategy*.sol` variants in repo.

### Top Results
- `Strategy_tmp_best_phase.sol`: **547.11**
- `Strategy_align_mix_best.sol`: **547.10**
- `Strategy.sol` / `Strategy_coord99_best.sol`: **546.91**

### Interpretation
- Confirmed global local ceiling in current repo families is ~547.1.
- No existing branch close to 555.

## Iteration 48 — Phase-Family Random Search (80 candidates around top file)

### Change
- Randomized 20+ constants around `Strategy_tmp_best_phase.sol` architecture.

### Result
- Best found: **546.92** (below family best 547.11).

### Diagnosis
- The phase-family optimum is narrow; randomized drift degrades quickly.
- No evidence of hidden >550 pocket in that neighborhood.

## Iteration 49 — 26-Slot Moonshot Revisit (gas root cause + runtime test)

### Finding: root cause of moonshot validation failure
- `Strategy_moonshot.sol` failed validation with:
  - `afterInitialize` out-of-gas at 250k.
- Root cause: too many zero→nonzero SSTORE writes in initialization path.

### Change
- Built lazy-init variants with fewer `afterInitialize` writes (`Strategy_moonshot_initfix.sol`, `Strategy_moonshot_initfix2.sol`).

### Result
- Validation passed.
- 10 sims remained very low: **368.84**.

### Diagnosis
- Failure was not only init gas; the architecture itself is economically miscalibrated in this simulator.

## Iteration 50 — Continuous Vulnerable-Floor Regime Module

### Change
- Added continuous lambda-dependent vulnerable floor and calm/storm vulnerable adjustments to baseline.
- Performed 112-candidate sweep over `(VULN_LAMBDA_ADD, CALM_VULN_CUT, STORM_VULN_ADD)`.

### Result
- Best: **546.91** (exact baseline), with many settings regressing to 546.77–546.89.

### Diagnosis
- Module is neutral or negative on deterministic 10-sim seeds.
- Flow-triggered adjustments did not materially activate/useful signal under this baseline.

---

## Current Best Frontier (this cycle)

### Best 10-sim local
- `Strategy_tmp_best_phase.sol`: **547.11**

### Best robust long-horizon among promoted candidates
- `Strategy_coord99_best.sol` / current robust baseline:
  - 10: **546.91**
  - 25: **539.67**
  - 99: **529.85**
  - 500: **523.25**

### Alternative (10-sim peak, weaker long-horizon)
- `Strategy_tmp_best_phase.sol`:
  - 10: **547.11**
  - 25: **539.25**
  - 99: **529.36**
  - 500: **522.82**

## Ceiling Update
- Despite multiple structural branches and large sweeps, no candidate exceeded **547.11** local 10-sim in this codebase cycle.
- The requested 555 target was not reached in this iteration set.

## Highest-Conviction Next Path
1. Refactor `afterSwap` into 2–3 helper functions to break `viaIR` stack limits while staying gas-safe.
2. Re-introduce higher-ceiling modules in compact form:
   - carry/continuation split,
   - hazard hysteresis,
   - lightweight PI flow controller.
3. Constrain `afterInitialize` to <=10 writes to avoid 250k init OOG.
4. Optimize with staged objective: 10-sim candidate discovery -> 25/99/500 robustness filter.

## Iteration 51 — Full 99-Sim Candidate Comparison + Permutation Search (High-Sim Objective)

### Motivation
- User request: prioritize comparisons at higher simulation counts when 10-sim values are similar.
- Implemented a full candidate ranking and combinatorial parameter sweeps with **99 sims as the objective**.

### Step A: Full candidate ranking (`Strategy*.sol` at 99 sims)
- Ran all local strategy files through `99` simulations.
- Top results:
  1. `Strategy.sol` = **529.85**
  2. `Strategy_coord99_best.sol` = **529.85**
  3. `Strategy_candidate_robust.sol` = **529.55**
  4. `Strategy_coord_from_tmp.sol` = **529.52**
  5. `Strategy_align_mix_best.sol` = **529.47**
  6. `Strategy_tmp_best_phase.sol` = **529.36**
- Many 10-sim-competitive variants degraded materially at 99 sims (e.g., several in 515–525 range; moonshot failures).

### Step B: 99-sim permutation matrix A (32 combos)
- Base architecture: current `Strategy.sol`.
- Exhaustive grid across:
  - `ARB_SIGMA_DIV ∈ {8,9}`
  - `SAFE_VOL_MULT_BPS ∈ {2347,2400}`
  - `INV_SENS_BPS ∈ {124,128}`
  - `SHOCK_RATIO_WAD ∈ {102,106}`
  - `CONT_ARB_REBATE_BPS ∈ {4,5}`
- Best result: **529.85** (tie only; no strict improvement).

### Step C: 99-sim permutation matrix B (32 combos)
- Exhaustive grid across:
  - `ARB_SIGMA_DIV ∈ {9,10}`
  - `SAFE_VOL_MULT_BPS ∈ {2400,2538}`
  - `INV_SENS_BPS ∈ {124,128}`
  - `SHOCK_RATIO_WAD ∈ {102,106}`
  - `SHOCK_BUMP_BPS ∈ {5,6}`
- Best result: **529.85** (tie only; no strict improvement).

### Step D: Tie-break on longer horizon
- Tested representative tie-best candidates on 25 and 500 sims.
- Results matched baseline:
  - 25 sims: **539.67**
  - 500 sims: **523.25**

### Conclusion
- The requested high-sim methodology was implemented:
  - full candidate comparison at 99,
  - then exhaustive 99-sim permutation combinations around top parameter sets,
  - then 25/500 tie-break confirmation.
- No candidate strictly beat current `Strategy.sol` on high-sim objectives in this cycle.

### Final status
- Keep `Strategy.sol` as current robust best:
  - 10: **546.91**
  - 25: **539.67**
  - 99: **529.85**
  - 500: **523.25**

## Iteration 52 — Structural Branches + Deep High-Sim Search (Post-523 Plateau)

### Baseline Re-anchor (updated simulator)
- `Strategy.sol` rechecked: 10=`546.91`, 99=`529.85`, 500=`523.25`.

### Structural branch tests (new families)
- `Strategy_hazard_mode.sol` (hazard state machine, mode switching): 10=`533.88` (regression).
- `Strategy_clock2.sol` (aggressive carry/continuation scheduling): 10=`542.83` (regression).
- `Strategy_prob.sol` (soft arb-probability weighting): compile-fixed variant reached 10=`543.38` (regression).
- `Strategy_barbell.sol` (low safe/high vuln): 10=`544.55` (regression).
- `Strategy_multiscale.sol` (fast+slow sigma/lambda blend): 10=`546.80`, 99=`529.89`, 500=`523.27` (small robustness gain, not best).
- `Strategy_lowlambda_guard.sol` (explicit low-lambda surcharge): 10=`546.91`, 99=`529.85` (neutral).
- `Strategy_stale_tax.sol` (staleness uncertainty tax): 10=`546.88`, 99=`529.85` (neutral).
- `Strategy_retail_step_compete.sol` (guarded continuation compete only when first trade non-arb): 10=`546.73`, 99=`529.78` (regression).

### High-sim parameter sweeps
1. Randomized 140-candidate sweep around baseline constants:
   - Best 10-sim candidate: `546.98`.
   - Best 99-sim candidate: `529.86`.
   - Best 500 among promoted finalists: `523.32`.
2. Targeted 180-candidate basin sweep around best-500 neighborhood (`25 -> 99 -> 500` funnel):
   - Best 99 candidate: `529.90`.
   - Best 500 candidate: **`523.40`**.
3. Focused probe around safe/vuln+inventory tradeoff near new basin:
   - Top pocket tied at 10=`546.92`, 99=`529.90`, 500=`523.40`.

### New best configuration promoted
- Promoted to `Strategy.sol` (renamed strategy to `BandShield_v5`).
- Verified:
  - 10 sims: **`546.92`**
  - 25 sims: **`539.60`**
  - 99 sims: **`529.90`**
  - 500 sims: **`523.40`**

### Best-known constants in this cycle (delta vs old Strategy.sol)
- `ARB_SIGMA_DIV: 9 -> 11`
- `ALPHA_P: 37e16 -> 35e16`
- `SAFE_VOL_MULT_BPS: 2400 -> 2300`
- `VULN_SIGMA_DIV: 16 -> 18`
- `ARMOR_SAFE_FLOOR: 17 -> 15`
- `INV_SENS_BPS: 128 -> 160`
- `INV_MAX_SKEW_BPS: 40 -> 38`
- `SHOCK_RATIO_WAD: 106 -> 112`
- `SHOCK_BUMP_BPS: 6 -> 4`
- `SHOCK_MAX_BPS: 18 -> 14`
- `PHAT_RECENTER_PER_STEP: 16e14 -> 12e14`
- `PHAT_RECENTER_MAX: 20e16 -> 18e16`
- `ALPHA_SLOW: 78e16 -> 77e16`

### Diagnostic takeaways
- This simulator remains strongly flow-driven: edge correlates much more with effective fill/routing than with raw sigma level.
- Multiple structural additions improved 99 marginally but did not produce a step-change at 500.
- Current observed ceiling in this workspace family moved from 523.25 -> **523.40** on 500, still materially below requested 530 target.
- Continuing likely requires a genuinely new fee policy family (not another local perturbation of the current asymmetric shield spine).

## Iteration 53 — Quick Parameter Edits Around Ghost Strategy

### Input architecture
- Started from `Strategy_ghost_tuned.sol` (already strong):
  - 10 = 552.95
  - 25 = 545.74
  - 99 = 536.44
  - 500 = 530.21

### Quick two-stage tune (fast pass)
1. Stage 1 (27 combos): tuned
- `PHAT_ALPHA` in {0.24, 0.28, 0.32}
- `LAMBDA_DECAY` in {0.994, 0.995, 0.996}
- `TOX_BLEND_DECAY` in {0.12, 0.15, 0.18}

Best Stage 1 pocket:
- `PHAT_ALPHA = 0.28`
- `LAMBDA_DECAY = 0.996`
- `TOX_BLEND_DECAY = 0.12`
- 10-sim = 553.13

2. Stage 2 (9 combos around stage1 winner): tuned
- `FLOW_SIZE_COEF` in {5200, 5600, 6000} * BPS
- `ACT_COEF` in {50000, 53500, 57000} * BPS

Best selected candidate:
- `FLOW_SIZE_COEF = 5600 * BPS`
- `ACT_COEF = 53500 * BPS`
- (same as baseline tuned values for these two)

### Final candidate
- File: `Strategy_ghost_quick.sol`
- Promoted into `Strategy.sol`
- Name: `BandShield_ghost_quick`

### Scores
- 10 sims: **553.13**
- 25 sims: **545.91**
- 99 sims: **536.56**
- 500 sims: **530.28**

### Net effect
- Improvement over prior ghost-tuned baseline:
  - +0.18 (10)
  - +0.17 (25)
  - +0.12 (99)
  - +0.07 (500)
