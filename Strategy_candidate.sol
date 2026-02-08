// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title BandShield Probabilistic Hazard
/// @notice Multi-timescale dynamic fee strategy with probabilistic arb inference,
/// hazard-gated carry/compete modes, and confidence-aware asymmetry.
contract Strategy is AMMStrategyBase {
    uint256 private constant MIN_FEE_BPS = 8;
    uint256 private constant MAX_FEE_BPS = 954;
    uint256 private constant MAX_SPREAD_BPS = 900;

    uint256 private constant ARB_BASE_RATIO_WAD = 40 * BPS;
    uint256 private constant ARB_SIGMA_DIV = 4;

    uint256 private constant ALPHA_P_FAST_ARB = 42e16;
    uint256 private constant ALPHA_P_SLOW_ARB = 11e16;
    uint256 private constant ALPHA_RECENTER_FAST = 8e16;
    uint256 private constant ALPHA_RECENTER_SLOW = 3e16;

    uint256 private constant ALPHA_VAR_FAST = 22e16;
    uint256 private constant ALPHA_VAR_SLOW = 5e16;

    uint256 private constant ALPHA_L_FAST = 22e16;
    uint256 private constant ALPHA_L_SLOW = 9e16;

    uint256 private constant SIGMA_MIN = 7 * BPS;
    uint256 private constant SIGMA_MAX = 24 * BPS;
    uint256 private constant SIGMA_FAST_WEIGHT = 75e16;

    uint256 private constant SAFE_CORE_BPS = 5;
    uint256 private constant SAFE_VOL_MULT_BPS = 2200;
    uint256 private constant SAFE_LAMBDA_SWING_BPS = 10;

    uint256 private constant COMPETE_CUT_BPS = 4;
    uint256 private constant CARRY_ADD_BPS = 7;
    uint256 private constant HAZARD_TO_CARRY_BPS = 2;

    uint256 private constant VULN_MIN_BPS = 52;
    uint256 private constant VULN_SIGMA_DIV = 12;
    uint256 private constant VULN_HAZ_DIV = 2;
    uint256 private constant VULN_BUFFER_BPS = 0;

    uint256 private constant LAMBDA_REF = WAD / 3;
    uint256 private constant ARMOR_LAMBDA = WAD / 5;
    uint256 private constant ARMOR_SIGMA = 10 * BPS;
    uint256 private constant ARMOR_SAFE_FLOOR = 21;
    uint256 private constant ARMOR_VULN_FLOOR = 72;

    uint256 private constant BASE_REBATE_BPS = 55;
    uint256 private constant MIN_REBATE_BPS = 16;
    uint256 private constant MAX_REBATE_BPS = 72;
    uint256 private constant HIGH_FLOW_REBATE_ADD_BPS = 6;
    uint256 private constant LOW_FLOW_REBATE_CUT_BPS = 8;
    uint256 private constant CONT_REBATE_BPS = 3;
    uint256 private constant CONF_AGE_CAP = 240;

    uint256 private constant TOX_MAX_BPS = 30;
    uint256 private constant TOX_DECAY_BPS = 1;
    uint256 private constant TOX_UP_BPS = 5;
    uint256 private constant TOX_DOWN_BPS = 4;
    uint256 private constant TOX_BIG_UP_BPS = 2;

    uint256 private constant SHOCK_RATIO_WAD = 90 * BPS;
    uint256 private constant BIG_RATIO_WAD = 45 * BPS;
    uint256 private constant SHOCK_BUMP_BPS = 7;
    uint256 private constant BIG_BUMP_BPS = 3;
    uint256 private constant SHOCK_DECAY_BPS = 1;
    uint256 private constant SHOCK_MAX_BPS = 18;

    uint256 private constant HAZARD_MAX = 40;
    uint256 private constant HAZARD_DECAY = 1;
    uint256 private constant HAZARD_UP_NONARB_FIRST = 5;
    uint256 private constant HAZARD_DOWN_ARB = 4;
    uint256 private constant HAZARD_IDLE_DIV = 4;
    uint256 private constant HAZARD_CARRY_ON = 18;
    uint256 private constant HAZARD_CARRY_OFF = 9;

    uint256 private constant STREAK_STEP_BPS = 1;
    uint256 private constant STREAK_MAX_BPS = 6;

    uint256 private constant INV_SENS_BPS = 92;
    uint256 private constant INV_MAX_SKEW_BPS = 56;

    uint256 private constant ALPHA_SLOW = 77e16;
    uint256 private constant ALPHA_MID = 88e16;
    uint256 private constant ALPHA_FAST = 100e16;

    // slot layout
    // [0] lastSeenTs
    // [1] lastArbTs
    // [2] lastBidFee
    // [3] lastAskFee
    // [4] pHatFast
    // [5] pHatSlow
    // [6] lastFair
    // [7] varFast
    // [8] varSlow
    // [9] lambdaFast
    // [10] lambdaSlow
    // [11] shockBps
    // [12] toxBps
    // [13] hazard
    // [14] mode (0 compete, 1 carry)
    // [15] lastSide
    // [16] streak
    // [17] stepTrades

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 spot = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        uint256 start = bpsToWad(37);

        bidFee = start;
        askFee = start;

        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = spot;
        slots[5] = spot;
        slots[6] = spot;
        slots[7] = wmul(10 * BPS, 10 * BPS);
        slots[8] = wmul(10 * BPS, 10 * BPS);
        slots[9] = LAMBDA_REF;
        slots[10] = LAMBDA_REF;
        slots[12] = 10;
        slots[13] = 14;
        slots[14] = 1;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastTs = slots[0];
        uint256 lastArbTs = slots[1];
        uint256 lastBid = slots[2];
        uint256 lastAsk = slots[3];
        uint256 pFast = slots[4];
        uint256 pSlow = slots[5];
        uint256 lastFair = slots[6];
        uint256 varFast = slots[7];
        uint256 varSlow = slots[8];
        uint256 lambdaFast = slots[9];
        uint256 lambdaSlow = slots[10];
        uint256 shockBps = slots[11];
        uint256 toxBps = slots[12];
        uint256 hazard = slots[13];
        uint256 mode = slots[14];
        uint256 lastSide = slots[15];
        uint256 streak = slots[16];
        uint256 stepTrades = slots[17];

        if (lastBid == 0) lastBid = bpsToWad(37);
        if (lastAsk == 0) lastAsk = bpsToWad(37);

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : 100 * WAD;
        if (pFast == 0) pFast = spot;
        if (pSlow == 0) pSlow = spot;
        if (lastFair == 0) lastFair = pSlow;
        if (varFast == 0) varFast = wmul(10 * BPS, 10 * BPS);
        if (varSlow == 0) varSlow = varFast;
        if (lambdaFast == 0) lambdaFast = LAMBDA_REF;
        if (lambdaSlow == 0) lambdaSlow = LAMBDA_REF;
        if (hazard == 0) hazard = 14;

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        bool firstInStep = trade.timestamp != lastTs;

        uint256 dt = 1;
        if (firstInStep && lastTs > 0 && trade.timestamp > lastTs) {
            dt = trade.timestamp - lastTs;
            uint256 instLambda = WAD / dt;
            lambdaFast = _ewma(lambdaFast, instLambda, ALPHA_L_FAST);
            lambdaSlow = _ewma(lambdaSlow, instLambda, ALPHA_L_SLOW);
        }

        // Use pre-update sigma for dynamic arb thresholding.
        uint256 sigmaFastNow = sqrt(varFast * WAD);
        uint256 sigmaSlowNow = sqrt(varSlow * WAD);
        if (sigmaFastNow < SIGMA_MIN) sigmaFastNow = SIGMA_MIN;
        if (sigmaFastNow > SIGMA_MAX) sigmaFastNow = SIGMA_MAX;
        if (sigmaSlowNow < SIGMA_MIN) sigmaSlowNow = SIGMA_MIN;
        if (sigmaSlowNow > SIGMA_MAX) sigmaSlowNow = SIGMA_MAX;
        uint256 sigmaPre = wmul(SIGMA_FAST_WEIGHT, sigmaFastNow) + wmul(WAD - SIGMA_FAST_WEIGHT, sigmaSlowNow);

        uint256 arbRatioCap = ARB_BASE_RATIO_WAD + (sigmaPre / ARB_SIGMA_DIV);
        bool likelySmall = tradeRatio <= arbRatioCap;

        bool aligned = true;
        if (pSlow > 0) {
            if (spot < pSlow) aligned = !trade.isBuy;
            else if (spot > pSlow) aligned = trade.isBuy;
        }

        uint256 arbScore = firstInStep ? 55 : 5;
        if (likelySmall) arbScore += 30;
        else if (tradeRatio <= BIG_RATIO_WAD) arbScore += 8;
        if (aligned) arbScore += 15;
        else if (arbScore > 12) arbScore -= 12;
        if (arbScore > 100) arbScore = 100;
        uint256 arbProb = arbScore * 1e16;
        bool likelyArb = arbProb >= 60e16;

        stepTrades = firstInStep ? 1 : (stepTrades + 1);

        // Update fair estimate and volatility using weighted arb probability.
        uint256 feeApplied = trade.isBuy ? lastBid : lastAsk;
        uint256 gamma = feeApplied < WAD ? (WAD - feeApplied) : 1;
        uint256 pEst = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);

        uint256 aFast = wmul(ALPHA_P_FAST_ARB, arbProb);
        uint256 aSlow = wmul(ALPHA_P_SLOW_ARB, arbProb);
        if (aFast > 0) pFast = _ewma(pFast, pEst, aFast);
        if (aSlow > 0) pSlow = _ewma(pSlow, pEst, aSlow);

        if (!likelyArb) {
            pFast = _ewma(pFast, spot, ALPHA_RECENTER_FAST);
            pSlow = _ewma(pSlow, pFast, ALPHA_RECENTER_SLOW);
        }

        if (lastFair > 0) {
            uint256 ratio = wdiv(pEst, lastFair);
            uint256 diff = ratio > WAD ? (ratio - WAD) : (WAD - ratio);
            uint256 sq = wmul(diff, diff);
            uint256 avf = wmul(ALPHA_VAR_FAST, arbProb);
            uint256 avs = wmul(ALPHA_VAR_SLOW, arbProb);
            if (avf > 0) varFast = _ewma(varFast, sq, avf);
            if (avs > 0) varSlow = _ewma(varSlow, sq, avs);
        }
        if (likelyArb) {
            lastFair = pEst;
            lastArbTs = trade.timestamp;
        }

        // Shock and toxicity state.
        if (shockBps > SHOCK_DECAY_BPS) shockBps -= SHOCK_DECAY_BPS;
        else shockBps = 0;
        if (tradeRatio >= SHOCK_RATIO_WAD) {
            shockBps = shockBps + SHOCK_BUMP_BPS > SHOCK_MAX_BPS ? SHOCK_MAX_BPS : shockBps + SHOCK_BUMP_BPS;
        } else if (tradeRatio >= BIG_RATIO_WAD) {
            shockBps = shockBps + BIG_BUMP_BPS > SHOCK_MAX_BPS ? SHOCK_MAX_BPS : shockBps + BIG_BUMP_BPS;
        }

        if (toxBps > TOX_DECAY_BPS) toxBps -= TOX_DECAY_BPS;
        else toxBps = 0;
        if (likelyArb) {
            toxBps = toxBps > TOX_DOWN_BPS ? (toxBps - TOX_DOWN_BPS) : 0;
        } else if (firstInStep) {
            toxBps += TOX_UP_BPS;
        }
        if (tradeRatio >= BIG_RATIO_WAD) toxBps += TOX_BIG_UP_BPS;
        if (toxBps > TOX_MAX_BPS) toxBps = TOX_MAX_BPS;

        // Hazard with hysteresis.
        if (hazard > HAZARD_DECAY) hazard -= HAZARD_DECAY;
        else hazard = 0;
        if (likelyArb) {
            hazard = hazard > HAZARD_DOWN_ARB ? (hazard - HAZARD_DOWN_ARB) : 0;
        } else if (firstInStep) {
            hazard += HAZARD_UP_NONARB_FIRST;
        }
        if (firstInStep && dt > 1) {
            uint256 idleAdd = dt / HAZARD_IDLE_DIV;
            if (idleAdd > 6) idleAdd = 6;
            hazard += idleAdd;
        }
        if (sigmaSlowNow > ARMOR_SIGMA && lambdaSlow < ARMOR_LAMBDA) hazard += 2;
        if (hazard > HAZARD_MAX) hazard = HAZARD_MAX;

        if (mode == 0) {
            if (hazard >= HAZARD_CARRY_ON) mode = 1;
        } else {
            if (hazard <= HAZARD_CARRY_OFF && toxBps <= 10) mode = 0;
        }

        // Side streak tracker.
        uint256 side = trade.isBuy ? 1 : 2;
        if (side == lastSide && side != 0) {
            streak += 1;
        } else {
            streak = 1;
            lastSide = side;
        }

        // Final sigma/lambda blend.
        uint256 sigmaFast = sqrt(varFast * WAD);
        uint256 sigmaSlow = sqrt(varSlow * WAD);
        if (sigmaFast < SIGMA_MIN) sigmaFast = SIGMA_MIN;
        if (sigmaFast > SIGMA_MAX) sigmaFast = SIGMA_MAX;
        if (sigmaSlow < SIGMA_MIN) sigmaSlow = SIGMA_MIN;
        if (sigmaSlow > SIGMA_MAX) sigmaSlow = SIGMA_MAX;
        uint256 sigma = wmul(SIGMA_FAST_WEIGHT, sigmaFast) + wmul(WAD - SIGMA_FAST_WEIGHT, sigmaSlow);
        uint256 sigmaBps = sigma / BPS;

        uint256 lambdaMix = wmul(65e16, lambdaFast) + wmul(35e16, lambdaSlow);

        uint256 safeBps = SAFE_CORE_BPS + ((sigma * SAFE_VOL_MULT_BPS) / WAD) + shockBps;
        if (lambdaMix >= LAMBDA_REF) {
            uint256 ex = wdiv(lambdaMix, LAMBDA_REF) - WAD;
            uint256 tight = (ex * SAFE_LAMBDA_SWING_BPS) / WAD;
            if (tight > SAFE_LAMBDA_SWING_BPS) tight = SAFE_LAMBDA_SWING_BPS;
            safeBps = tight < safeBps ? (safeBps - tight) : safeBps;
        } else {
            uint256 def = WAD - wdiv(lambdaMix, LAMBDA_REF);
            uint256 wid = (def * SAFE_LAMBDA_SWING_BPS) / WAD;
            if (wid > SAFE_LAMBDA_SWING_BPS) wid = SAFE_LAMBDA_SWING_BPS;
            safeBps += wid;
        }

        if (mode == 1) {
            safeBps += CARRY_ADD_BPS + (hazard / HAZARD_TO_CARRY_BPS);
        } else {
            safeBps = safeBps > COMPETE_CUT_BPS ? (safeBps - COMPETE_CUT_BPS) : MIN_FEE_BPS;
        }

        uint256 vulnFloor = VULN_MIN_BPS + (sigmaBps / VULN_SIGMA_DIV) + (hazard / VULN_HAZ_DIV);

        if (lambdaSlow < ARMOR_LAMBDA && sigma > ARMOR_SIGMA) {
            if (safeBps < ARMOR_SAFE_FLOOR) safeBps = ARMOR_SAFE_FLOOR;
            if (vulnFloor < ARMOR_VULN_FLOOR) vulnFloor = ARMOR_VULN_FLOOR;
            mode = 1;
        }

        if (safeBps < MIN_FEE_BPS) safeBps = MIN_FEE_BPS;

        uint256 bidBps = safeBps;
        uint256 askBps = safeBps;

        // Confidence-aware rebate for the safe side.
        uint256 calmRatio = SIGMA_MAX > SIGMA_MIN ? ((SIGMA_MAX - sigma) * WAD) / (SIGMA_MAX - SIGMA_MIN) : 0;
        uint256 confRatio = WAD;
        if (lastArbTs > 0 && trade.timestamp > lastArbTs) {
            uint256 age = trade.timestamp - lastArbTs;
            if (age >= CONF_AGE_CAP) confRatio = 0;
            else confRatio = ((CONF_AGE_CAP - age) * WAD) / CONF_AGE_CAP;
        }

        uint256 rebate = (BASE_REBATE_BPS * calmRatio) / WAD;
        rebate = (rebate * confRatio) / WAD;
        if (lambdaSlow > LAMBDA_REF) rebate += HIGH_FLOW_REBATE_ADD_BPS;
        else rebate = rebate > LOW_FLOW_REBATE_CUT_BPS ? rebate - LOW_FLOW_REBATE_CUT_BPS : 0;
        if (mode == 1 || hazard >= HAZARD_CARRY_ON) rebate /= 2;
        if (!firstInStep && hazard <= HAZARD_CARRY_OFF) rebate += CONT_REBATE_BPS;
        if (rebate < MIN_REBATE_BPS) rebate = MIN_REBATE_BPS;
        if (rebate > MAX_REBATE_BPS) rebate = MAX_REBATE_BPS;

        // Shield by mispricing; rebate safe side only.
        if (pSlow > 0) {
            if (spot < pSlow) {
                uint256 spotOverFair = wdiv(spot, pSlow);
                uint256 reqAsk = WAD > spotOverFair ? (WAD - spotOverFair) : 0;
                uint256 reqAskBps = (reqAsk / BPS) + VULN_BUFFER_BPS;
                if (reqAskBps < vulnFloor) reqAskBps = vulnFloor;
                askBps = reqAskBps;
                bidBps = bidBps > rebate ? (bidBps - rebate) : MIN_FEE_BPS;
            } else if (spot > pSlow) {
                uint256 fairOverSpot = wdiv(pSlow, spot);
                uint256 reqBid = WAD > fairOverSpot ? (WAD - fairOverSpot) : 0;
                uint256 reqBidBps = (reqBid / BPS) + VULN_BUFFER_BPS;
                if (reqBidBps < vulnFloor) reqBidBps = vulnFloor;
                bidBps = reqBidBps;
                askBps = askBps > rebate ? (askBps - rebate) : MIN_FEE_BPS;
            }
        }

        // Directional toxicity application.
        uint256 toxBid = toxBps;
        uint256 toxAsk = toxBps;
        if (streak >= 2) {
            if (lastSide == 1) {
                toxBid += toxBps / 3;
                toxAsk = toxAsk > toxBps / 4 ? (toxAsk - toxBps / 4) : 0;
            } else if (lastSide == 2) {
                toxAsk += toxBps / 3;
                toxBid = toxBid > toxBps / 4 ? (toxBid - toxBps / 4) : 0;
            }
        }
        bidBps += toxBid;
        askBps += toxAsk;

        // Inventory skew around x* from fair estimate.
        if (trade.reserveX > 0 && trade.reserveY > 0 && pSlow > 0) {
            uint256 k = trade.reserveX * trade.reserveY;
            uint256 xStar = sqrt(wdiv(k, pSlow));
            if (xStar > 0) {
                uint256 absQ = trade.reserveX > xStar
                    ? wdiv(trade.reserveX - xStar, xStar)
                    : wdiv(xStar - trade.reserveX, xStar);
                uint256 skew = (absQ * INV_SENS_BPS) / WAD;
                if (skew > INV_MAX_SKEW_BPS) skew = INV_MAX_SKEW_BPS;
                if (trade.reserveX > xStar) {
                    bidBps += skew;
                    askBps = askBps > skew ? (askBps - skew) : MIN_FEE_BPS;
                } else if (trade.reserveX < xStar) {
                    askBps += skew;
                    bidBps = bidBps > skew ? (bidBps - skew) : MIN_FEE_BPS;
                }
            }
        }

        // Small side-specific streak bump.
        if (streak >= 3) {
            uint256 bump = (streak - 2) * STREAK_STEP_BPS;
            if (bump > STREAK_MAX_BPS) bump = STREAK_MAX_BPS;
            if (lastSide == 1) bidBps += bump;
            else if (lastSide == 2) askBps += bump;
        }

        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);
        if (bidBps > askBps + MAX_SPREAD_BPS) bidBps = askBps + MAX_SPREAD_BPS;
        if (askBps > bidBps + MAX_SPREAD_BPS) askBps = bidBps + MAX_SPREAD_BPS;

        uint256 alpha = ALPHA_SLOW;
        if (likelyArb || tradeRatio >= SHOCK_RATIO_WAD) alpha = ALPHA_FAST;
        else if (firstInStep) alpha = ALPHA_MID;

        bidFee = _clampFeeRange(wmul(alpha, bpsToWad(bidBps)) + wmul(WAD - alpha, lastBid));
        askFee = _clampFeeRange(wmul(alpha, bpsToWad(askBps)) + wmul(WAD - alpha, lastAsk));

        slots[0] = trade.timestamp;
        slots[1] = lastArbTs;
        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = pFast;
        slots[5] = pSlow;
        slots[6] = lastFair;
        slots[7] = varFast;
        slots[8] = varSlow;
        slots[9] = lambdaFast;
        slots[10] = lambdaSlow;
        slots[11] = shockBps;
        slots[12] = toxBps;
        slots[13] = hazard;
        slots[14] = mode;
        slots[15] = lastSide;
        slots[16] = streak;
        slots[17] = stepTrades;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_probx";
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
}
