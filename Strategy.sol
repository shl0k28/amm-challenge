// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title BandShield v1
/// @notice Dynamic fees with side-specific no-arbitrage shielding:
/// - infer fair price from likely-arb prints
/// - estimate sigma from arb-implied fair returns
/// - set a high defensive baseline
/// - harden only the vulnerable side when spot diverges from estimated fair
/// - keep the opposite side cheaper to preserve rebalancing flow
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Hard bounds in basis points.
    uint256 private constant MIN_FEE_BPS = 20;
    uint256 private constant MAX_FEE_BPS = 708;
    uint256 private constant MAX_SPREAD_BPS = 933;

    // Defensive core fee: this simulator rewards stale-price protection.
    uint256 private constant CORE_BPS = 46;
    uint256 private constant VOL_MULT_BPS = 1205; // +1.205 bps per 10 bps sigma
    uint256 private constant BASE_MIN_BPS = 31;

    // Arrival-rate adjustment: slower fills -> widen, faster -> tighten a bit.
    uint256 private constant LAMBDA_REF = WAD / 3; // ~0.333 fills/step
    uint256 private constant FLOW_SWING_BPS = 13;
    uint256 private constant LOWLAM_SIGMA_WIDEN_BPS = 28;

    // Fair/vol estimation from likely-arb prints.
    uint256 private constant ARB_MAX_RATIO_WAD = 21 * BPS; // <= 0.21% of reserveY
    uint256 private constant ALPHA_P = 35e16; // 0.35
    uint256 private constant ALPHA_VAR = 20e16; // 0.20
    uint256 private constant ALPHA_L = 14e16; // 0.14

    // Sigma clamps (WAD, where 1 bps = 1e14).
    uint256 private constant SIGMA_MIN = 7 * BPS;
    uint256 private constant SIGMA_MAX = 24 * BPS;

    // Side-specific no-arb shield from spot/fair divergence.
    // If spot < pHat, ask side is vulnerable: fee >= (1 - spot/pHat) + buffers.
    // If spot > pHat, bid side is vulnerable: fee >= (1 - pHat/spot) + buffers.
    uint256 private constant SHIELD_SAFETY_BPS = 2;
    uint256 private constant VOL_BUFFER_DIV = 5; // add sigma/5 as extra band safety
    uint256 private constant SAFE_SIDE_REBATE_BPS = 37;

    // Intra-step continuation rebate: if multiple trades hit in same timestamp,
    // later fills are retail-only (arb already happened), so we can undercut.
    uint256 private constant INTRASTEP_REBATE_BPS = 0;

    // Shock/streak toxicity on the active side.
    uint256 private constant SHOCK_RATIO_WAD = 90 * BPS; // 0.90%
    uint256 private constant BIG_RATIO_WAD = 45 * BPS; // 0.45%
    uint256 private constant SHOCK_BUMP_BPS = 10;
    uint256 private constant BIG_BUMP_BPS = 4;
    uint256 private constant SHOCK_DECAY_BPS = 1;
    uint256 private constant SHOCK_MAX_BPS = 18;
    uint256 private constant STREAK_STEP_BPS = 2;
    uint256 private constant STREAK_MAX_BPS = 8;

    // Inventory skew around x* = sqrt(k / pHat).
    uint256 private constant INV_SENS_BPS = 90;
    uint256 private constant INV_MAX_SKEW_BPS = 18;

    // Event toxicity state: high after first-trade retail, low after arb resets.
    uint256 private constant TOX_MAX_BPS = 21;
    uint256 private constant TOX_DECAY_BPS = 1;
    uint256 private constant TOX_UP_BPS = 3;
    uint256 private constant TOX_DOWN_BPS = 3;
    uint256 private constant TOX_BIG_UP_BPS = 4;

    // Fee smoothing.
    uint256 private constant ALPHA_SLOW = 71e16; // 0.71
    uint256 private constant ALPHA_FAST = 100e16; // 1.00

    /*//////////////////////////////////////////////////////////////
                               SLOT LAYOUT
    //////////////////////////////////////////////////////////////*/
    // [0] lastSeenTs
    // [1] spare
    // [2] lastBidFee
    // [3] lastAskFee
    // [4] pHat
    // [5] lastFair
    // [6] varEWMA
    // [7] lambdaEWMA
    // [8] shockBps
    // [9] lastSide (1=AMM buys X, 2=AMM sells X)
    // [10] sameSideStreak
    // [11] tradesThisStep
    // [13] toxBps

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 spot = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        uint256 start = bpsToWad(CORE_BPS);

        bidFee = start;
        askFee = start;

        // Keep init writes lean for the strict gas budget.
        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = spot;
        slots[5] = spot;
        slots[6] = wmul(10 * BPS, 10 * BPS); // seed var ~ (10 bps)^2
        slots[7] = LAMBDA_REF;
        slots[13] = 10;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastSeenTs = slots[0];
        uint256 lastBid = slots[2];
        uint256 lastAsk = slots[3];
        uint256 pHat = slots[4];
        uint256 lastFair = slots[5];
        uint256 varEWMA = slots[6];
        uint256 lambdaEWMA = slots[7];
        uint256 shockBps = slots[8];
        uint256 lastSide = slots[9];
        uint256 streak = slots[10];
        uint256 stepTrades = slots[11];
        uint256 toxBps = slots[13];

        if (lastBid == 0) lastBid = bpsToWad(CORE_BPS);
        if (lastAsk == 0) lastAsk = bpsToWad(CORE_BPS);
        if (pHat == 0) pHat = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : 100 * WAD;
        if (lastFair == 0) lastFair = pHat;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        bool firstInStep = trade.timestamp != lastSeenTs;
        uint256 dtSteps = 1;
        if (firstInStep && lastSeenTs > 0 && trade.timestamp > lastSeenTs) {
            dtSteps = trade.timestamp - lastSeenTs;
            uint256 instLambda = WAD / dtSteps;
            lambdaEWMA = _ewma(lambdaEWMA, instLambda, ALPHA_L);
        }
        bool likelyArb = firstInStep && (tradeRatio <= ARB_MAX_RATIO_WAD);
        stepTrades = firstInStep ? 1 : (stepTrades + 1);

        // Update side streak.
        uint256 side = trade.isBuy ? 1 : 2;
        if (side == lastSide && side != 0) {
            streak += 1;
        } else {
            streak = 1;
            lastSide = side;
        }

        /*//////////////////////////////////////////////////////////////
                            1) BELIEF UPDATES
        //////////////////////////////////////////////////////////////*/
        if (likelyArb) {
            // Arb inversion:
            // isBuy=true  -> spot ~ p/gamma  => p ~ spot*gamma
            // isBuy=false -> spot ~ gamma*p  => p ~ spot/gamma
            uint256 feeApplied = trade.isBuy ? lastBid : lastAsk;
            uint256 gamma = feeApplied < WAD ? (WAD - feeApplied) : 1;
            uint256 pEst = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);

            pHat = _ewma(pHat, pEst, ALPHA_P);

            uint256 ratio = lastFair > 0 ? wdiv(pEst, lastFair) : WAD;
            uint256 diff = ratio > WAD ? (ratio - WAD) : (WAD - ratio);
            uint256 sq = wmul(diff, diff);
            varEWMA = _ewma(varEWMA, sq, ALPHA_VAR);
            lastFair = pEst;
        } else {
            // Lightly mean-recenter pHat when we do not observe arb prints.
            pHat = _ewma(pHat, spot, 6e16); // 0.06
        }

        // Update event-toxicity state.
        if (toxBps > TOX_DECAY_BPS) toxBps -= TOX_DECAY_BPS;
        else toxBps = 0;
        if (firstInStep) {
            if (likelyArb) {
                toxBps = toxBps > TOX_DOWN_BPS ? (toxBps - TOX_DOWN_BPS) : 0;
            } else {
                toxBps = _minU(toxBps + TOX_UP_BPS, TOX_MAX_BPS);
            }
        }
        if (tradeRatio >= BIG_RATIO_WAD) {
            toxBps = _minU(toxBps + TOX_BIG_UP_BPS, TOX_MAX_BPS);
        }

        // Shock state (Hawkes-lite with linear decay).
        if (shockBps > SHOCK_DECAY_BPS) shockBps -= SHOCK_DECAY_BPS;
        else shockBps = 0;
        if (tradeRatio >= SHOCK_RATIO_WAD) {
            shockBps = _minU(shockBps + SHOCK_BUMP_BPS, SHOCK_MAX_BPS);
        } else if (tradeRatio >= BIG_RATIO_WAD) {
            shockBps = _minU(shockBps + BIG_BUMP_BPS, SHOCK_MAX_BPS);
        }

        /*//////////////////////////////////////////////////////////////
                            2) BASELINE FEE
        //////////////////////////////////////////////////////////////*/
        uint256 sigma = sqrt(varEWMA * WAD);
        if (sigma < SIGMA_MIN) sigma = SIGMA_MIN;
        if (sigma > SIGMA_MAX) sigma = SIGMA_MAX;

        uint256 baseBps = CORE_BPS + ((sigma * VOL_MULT_BPS) / WAD) + shockBps;
        if (baseBps < BASE_MIN_BPS) baseBps = BASE_MIN_BPS;
        baseBps += toxBps;

        if (lambdaEWMA > 0) {
            if (lambdaEWMA >= LAMBDA_REF) {
                uint256 excess = wdiv(lambdaEWMA, LAMBDA_REF) - WAD;
                uint256 tight = (excess * FLOW_SWING_BPS) / WAD;
                if (tight > FLOW_SWING_BPS) tight = FLOW_SWING_BPS;
                baseBps = tight < baseBps ? (baseBps - tight) : baseBps;
            } else {
                uint256 deficit = WAD - wdiv(lambdaEWMA, LAMBDA_REF);
                uint256 widen = (deficit * FLOW_SWING_BPS) / WAD;
                if (widen > FLOW_SWING_BPS) widen = FLOW_SWING_BPS;
                baseBps += widen;
            }
        }

        // Extra defense in sparse + volatile regimes where adverse selection dominates.
        if (lambdaEWMA < LAMBDA_REF && sigma > (10 * BPS)) {
            uint256 stress = WAD - wdiv(lambdaEWMA, LAMBDA_REF);
            uint256 extra = (stress * LOWLAM_SIGMA_WIDEN_BPS) / WAD;
            baseBps += extra;
        }

        /*//////////////////////////////////////////////////////////////
                     3) SIDE-SPECIFIC BAND SHIELD
        //////////////////////////////////////////////////////////////*/
        uint256 bidBps = baseBps;
        uint256 askBps = baseBps;

        if (pHat > 0) {
            uint256 volBufferBps = (sigma / BPS) / VOL_BUFFER_DIV;

            if (spot < pHat) {
                // Ask side vulnerable.
                uint256 spotOverFair = wdiv(spot, pHat); // < 1
                uint256 reqAsk = (WAD > spotOverFair) ? (WAD - spotOverFair) : 0;
                uint256 reqAskBps = (reqAsk / BPS) + SHIELD_SAFETY_BPS + volBufferBps;
                if (askBps < reqAskBps) askBps = reqAskBps;
                bidBps = bidBps > SAFE_SIDE_REBATE_BPS ? (bidBps - SAFE_SIDE_REBATE_BPS) : MIN_FEE_BPS;
            } else if (spot > pHat) {
                // Bid side vulnerable.
                uint256 fairOverSpot = wdiv(pHat, spot); // < 1
                uint256 reqBid = (WAD > fairOverSpot) ? (WAD - fairOverSpot) : 0;
                uint256 reqBidBps = (reqBid / BPS) + SHIELD_SAFETY_BPS + volBufferBps;
                if (bidBps < reqBidBps) bidBps = reqBidBps;
                askBps = askBps > SAFE_SIDE_REBATE_BPS ? (askBps - SAFE_SIDE_REBATE_BPS) : MIN_FEE_BPS;
            }
        }

        /*//////////////////////////////////////////////////////////////
                       4) INVENTORY + FLOW TOXICITY
        //////////////////////////////////////////////////////////////*/
        if (trade.reserveX > 0 && trade.reserveY > 0 && pHat > 0) {
            uint256 k = trade.reserveX * trade.reserveY;
            uint256 xStar = sqrt(wdiv(k, pHat));
            if (xStar > 0) {
                uint256 absQ = trade.reserveX > xStar
                    ? wdiv(trade.reserveX - xStar, xStar)
                    : wdiv(xStar - trade.reserveX, xStar);

                uint256 invSkew = (absQ * INV_SENS_BPS) / WAD;
                if (invSkew > INV_MAX_SKEW_BPS) invSkew = INV_MAX_SKEW_BPS;

                if (trade.reserveX > xStar) {
                    // Long X: discourage more X-in, encourage X-out.
                    bidBps += invSkew;
                    askBps = askBps > invSkew ? (askBps - invSkew) : MIN_FEE_BPS;
                } else if (trade.reserveX < xStar) {
                    // Short X: discourage more X-out, encourage X-in.
                    askBps += invSkew;
                    bidBps = bidBps > invSkew ? (bidBps - invSkew) : MIN_FEE_BPS;
                }
            }
        }

        if (streak >= 3) {
            uint256 streakBump = (streak - 2) * STREAK_STEP_BPS;
            if (streakBump > STREAK_MAX_BPS) streakBump = STREAK_MAX_BPS;
            if (side == 1) bidBps += streakBump;
            else askBps += streakBump;
        }

        if (tradeRatio >= SHOCK_RATIO_WAD) {
            if (side == 1) bidBps += BIG_BUMP_BPS;
            else askBps += BIG_BUMP_BPS;
        }

        // Retail-continuation mode within the same step.
        if (!firstInStep && stepTrades >= 2 && tradeRatio <= BIG_RATIO_WAD && shockBps == 0) {
            bidBps = bidBps > INTRASTEP_REBATE_BPS ? (bidBps - INTRASTEP_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > INTRASTEP_REBATE_BPS ? (askBps - INTRASTEP_REBATE_BPS) : MIN_FEE_BPS;
        }

        // Bound BPS and spread.
        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);
        if (bidBps > askBps + MAX_SPREAD_BPS) bidBps = askBps + MAX_SPREAD_BPS;
        if (askBps > bidBps + MAX_SPREAD_BPS) askBps = bidBps + MAX_SPREAD_BPS;
        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);

        /*//////////////////////////////////////////////////////////////
                              5) SMOOTH + STORE
        //////////////////////////////////////////////////////////////*/
        uint256 alpha = (likelyArb || tradeRatio >= SHOCK_RATIO_WAD) ? ALPHA_FAST : ALPHA_SLOW;
        uint256 newBid = bpsToWad(bidBps);
        uint256 newAsk = bpsToWad(askBps);

        bidFee = wmul(alpha, newBid) + wmul(WAD - alpha, lastBid);
        askFee = wmul(alpha, newAsk) + wmul(WAD - alpha, lastAsk);
        bidFee = _clampFeeRange(bidFee);
        askFee = _clampFeeRange(askFee);

        // Persist.
        slots[0] = trade.timestamp;
        slots[1] = 0;
        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = pHat;
        slots[5] = lastFair;
        slots[6] = varEWMA;
        slots[7] = lambdaEWMA;
        slots[8] = shockBps;
        slots[9] = lastSide;
        slots[10] = streak;
        slots[11] = stepTrades;
        slots[13] = toxBps;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_v4";
    }

    function _ewma(uint256 prev, uint256 sample, uint256 alpha) internal pure returns (uint256) {
        return wmul(prev, WAD - alpha) + wmul(sample, alpha);
    }

    function _clampBps(uint256 bps) internal pure returns (uint256) {
        if (bps < MIN_FEE_BPS) return MIN_FEE_BPS;
        if (bps > MAX_FEE_BPS) return MAX_FEE_BPS;
        return bps;
    }

    function _clampFeeRange(uint256 fee) internal pure returns (uint256) {
        uint256 f = clampFee(fee);
        uint256 lo = bpsToWad(MIN_FEE_BPS);
        uint256 hi = bpsToWad(MAX_FEE_BPS);
        if (f < lo) return lo;
        if (f > hi) return hi;
        return f;
    }

    function _minU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
