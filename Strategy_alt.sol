// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    uint256 private constant MIN_FEE_BPS = 10;
    uint256 private constant MAX_FEE_BPS = 954;
    uint256 private constant MAX_SPREAD_BPS = 856;

    uint256 private constant CORE_BPS = 44;
    uint256 private constant VOL_MULT_BPS = 1080;
    uint256 private constant BASE_MIN_BPS = 20;

    uint256 private constant LAMBDA_REF = WAD / 3;
    uint256 private constant FLOW_SWING_BPS = 4;
    uint256 private constant LOWLAM_SIGMA_WIDEN_BPS = 7;
    uint256 private constant ARMOR_LAMBDA = 20e16;
    uint256 private constant ARMOR_SIGMA = 10 * BPS;
    uint256 private constant ARMOR_MIN_BPS = 110;

    uint256 private constant ARB_MAX_RATIO_WAD = 50 * BPS;
    uint256 private constant ALPHA_P = 35e16;
    uint256 private constant ALPHA_VAR = 20e16;
    uint256 private constant ALPHA_L = 14e16;
    uint256 private constant ALPHA_FIRST_ARB = 15e16;

    uint256 private constant SIGMA_MIN = 7 * BPS;
    uint256 private constant SIGMA_MAX = 24 * BPS;

    uint256 private constant SHIELD_SAFETY_BPS = 0;
    uint256 private constant VOL_BUFFER_DIV = 7;
    uint256 private constant SAFE_SIDE_REBATE_BPS = 42;

    uint256 private constant SHOCK_RATIO_WAD = 90 * BPS;
    uint256 private constant BIG_RATIO_WAD = 45 * BPS;
    uint256 private constant SHOCK_BUMP_BPS = 9;
    uint256 private constant BIG_BUMP_BPS = 4;
    uint256 private constant SHOCK_DECAY_BPS = 1;
    uint256 private constant SHOCK_MAX_BPS = 18;
    uint256 private constant STREAK_STEP_BPS = 1;
    uint256 private constant STREAK_MAX_BPS = 5;

    uint256 private constant INV_SENS_BPS = 280;
    uint256 private constant INV_MAX_SKEW_BPS = 62;

    uint256 private constant TOX_MAX_BPS = 28;
    uint256 private constant TOX_DECAY_BPS = 1;
    uint256 private constant TOX_UP_BPS = 4;
    uint256 private constant TOX_DOWN_BPS = 2;
    uint256 private constant TOX_BIG_UP_BPS = 3;

    // First-trade auction layer.
    uint256 private constant CONT_ARB_REBATE_BPS = 10;
    uint256 private constant CONT_RETAIL_REBATE_BPS = 3;
    uint256 private constant CONT_TAIL_REBATE_BPS = 2;

    uint256 private constant CARRY_BASE_BPS = 2;
    uint256 private constant CARRY_SIGMA_DIV = 4;
    uint256 private constant CARRY_NOARB_DIV = 10;
    uint256 private constant CARRY_ARB_BIAS_BPS = 3;
    uint256 private constant CARRY_MAX_BPS = 18;

    uint256 private constant ALPHA_SLOW = 82e16;
    uint256 private constant ALPHA_FAST = 100e16;

    // Slot layout baseline + auction extension.
    // [0] lastSeenTs
    // [2] lastBid
    // [3] lastAsk
    // [4] pHat
    // [5] lastFair
    // [6] varEWMA
    // [7] lambdaEWMA
    // [8] shockBps
    // [9] lastSide
    // [10] streak
    // [11] stepTrades
    // [13] toxBps
    // [14] firstArbEwma
    // [15] carryBpsState
    // [16] noArbSteps

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 spot = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        uint256 start = bpsToWad(CORE_BPS + 2);
        bidFee = start;
        askFee = start;

        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = spot;
        slots[5] = spot;
        slots[6] = wmul(10 * BPS, 10 * BPS);
        slots[7] = LAMBDA_REF;
        slots[13] = 10;
        slots[15] = CARRY_BASE_BPS;
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
        uint256 firstArbEwma = slots[14];
        uint256 carryBps = slots[15];
        uint256 noArbSteps = slots[16];

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
            if (dtSteps > 1) noArbSteps = _minU(noArbSteps + (dtSteps - 1), 300);
        }

        bool likelyArb = firstInStep && (tradeRatio <= ARB_MAX_RATIO_WAD);
        stepTrades = firstInStep ? 1 : (stepTrades + 1);

        uint256 side = trade.isBuy ? 1 : 2;
        if (side == lastSide && side != 0) streak += 1;
        else {
            streak = 1;
            lastSide = side;
        }

        if (likelyArb) {
            uint256 feeApplied = trade.isBuy ? lastBid : lastAsk;
            uint256 gamma = feeApplied < WAD ? (WAD - feeApplied) : 1;
            uint256 pEst = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);

            pHat = _ewma(pHat, pEst, ALPHA_P);
            uint256 ratio = lastFair > 0 ? wdiv(pEst, lastFair) : WAD;
            uint256 diff = ratio > WAD ? (ratio - WAD) : (WAD - ratio);
            uint256 sq = wmul(diff, diff);
            varEWMA = _ewma(varEWMA, sq, ALPHA_VAR);
            lastFair = pEst;

            noArbSteps = 0;
            firstArbEwma = _ewma(firstArbEwma, WAD, ALPHA_FIRST_ARB);
        } else {
            pHat = _ewma(pHat, spot, 6e16);
            if (firstInStep) noArbSteps = _minU(noArbSteps + 1, 300);
            firstArbEwma = _ewma(firstArbEwma, 0, ALPHA_FIRST_ARB);
        }

        // Toxicity + shock.
        if (toxBps > TOX_DECAY_BPS) toxBps -= TOX_DECAY_BPS;
        else toxBps = 0;
        if (firstInStep) {
            if (likelyArb) toxBps = toxBps > TOX_DOWN_BPS ? (toxBps - TOX_DOWN_BPS) : 0;
            else toxBps = _minU(toxBps + TOX_UP_BPS, TOX_MAX_BPS);
        }
        if (tradeRatio >= BIG_RATIO_WAD) toxBps = _minU(toxBps + TOX_BIG_UP_BPS, TOX_MAX_BPS);

        if (shockBps > SHOCK_DECAY_BPS) shockBps -= SHOCK_DECAY_BPS;
        else shockBps = 0;
        if (tradeRatio >= SHOCK_RATIO_WAD) shockBps = _minU(shockBps + SHOCK_BUMP_BPS, SHOCK_MAX_BPS);
        else if (tradeRatio >= BIG_RATIO_WAD) shockBps = _minU(shockBps + BIG_BUMP_BPS, SHOCK_MAX_BPS);

        uint256 sigma = sqrt(varEWMA * WAD);
        if (sigma < SIGMA_MIN) sigma = SIGMA_MIN;
        if (sigma > SIGMA_MAX) sigma = SIGMA_MAX;
        uint256 sigmaBps = sigma / BPS;

        uint256 baseBps = CORE_BPS + ((sigma * VOL_MULT_BPS) / WAD) + shockBps + toxBps;
        if (baseBps < BASE_MIN_BPS) baseBps = BASE_MIN_BPS;

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

        if (lambdaEWMA < LAMBDA_REF && sigma > 10 * BPS) {
            uint256 stress = WAD - wdiv(lambdaEWMA, LAMBDA_REF);
            uint256 extra = (stress * LOWLAM_SIGMA_WIDEN_BPS) / WAD;
            baseBps += extra;
        }

        if (lambdaEWMA < ARMOR_LAMBDA && sigma > ARMOR_SIGMA && baseBps < ARMOR_MIN_BPS) {
            baseBps = ARMOR_MIN_BPS;
        }

        uint256 bidBps = baseBps;
        uint256 askBps = baseBps;

        if (pHat > 0) {
            uint256 volBufferBps = sigmaBps / VOL_BUFFER_DIV;
            uint256 safeRebate = SAFE_SIDE_REBATE_BPS;
            if (firstArbEwma > 50e16) safeRebate = (safeRebate * 3) / 4;

            if (spot < pHat) {
                uint256 spotOverFair = wdiv(spot, pHat);
                uint256 reqAsk = (WAD > spotOverFair) ? (WAD - spotOverFair) : 0;
                uint256 reqAskBps = (reqAsk / BPS) + SHIELD_SAFETY_BPS + volBufferBps;
                if (askBps < reqAskBps) askBps = reqAskBps;
                bidBps = bidBps > safeRebate ? (bidBps - safeRebate) : MIN_FEE_BPS;
            } else if (spot > pHat) {
                uint256 fairOverSpot = wdiv(pHat, spot);
                uint256 reqBid = (WAD > fairOverSpot) ? (WAD - fairOverSpot) : 0;
                uint256 reqBidBps = (reqBid / BPS) + SHIELD_SAFETY_BPS + volBufferBps;
                if (bidBps < reqBidBps) bidBps = reqBidBps;
                askBps = askBps > safeRebate ? (askBps - safeRebate) : MIN_FEE_BPS;
            }
        }

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
                    bidBps += invSkew;
                    askBps = askBps > invSkew ? (askBps - invSkew) : MIN_FEE_BPS;
                } else if (trade.reserveX < xStar) {
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

        // First-print vs continuation pricing.
        if (firstInStep && shockBps == 0) {
            uint256 r = likelyArb ? CONT_ARB_REBATE_BPS : CONT_RETAIL_REBATE_BPS;
            bidBps = bidBps > r ? (bidBps - r) : MIN_FEE_BPS;
            askBps = askBps > r ? (askBps - r) : MIN_FEE_BPS;
            carryBps = 0;
        } else if (!firstInStep && stepTrades >= 2 && tradeRatio <= BIG_RATIO_WAD && shockBps == 0) {
            bidBps = bidBps > CONT_TAIL_REBATE_BPS ? (bidBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > CONT_TAIL_REBATE_BPS ? (askBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;

            uint256 prem = CARRY_BASE_BPS + (sigmaBps / CARRY_SIGMA_DIV) + (_minU(noArbSteps, 40) / CARRY_NOARB_DIV);
            if (firstArbEwma > 45e16) prem += CARRY_ARB_BIAS_BPS;
            if (prem > CARRY_MAX_BPS) prem = CARRY_MAX_BPS;
            carryBps = prem;
        }

        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);
        if (bidBps > askBps + MAX_SPREAD_BPS) bidBps = askBps + MAX_SPREAD_BPS;
        if (askBps > bidBps + MAX_SPREAD_BPS) askBps = bidBps + MAX_SPREAD_BPS;
        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);

        uint256 alpha = (likelyArb || tradeRatio >= SHOCK_RATIO_WAD) ? ALPHA_FAST : ALPHA_SLOW;
        uint256 newBid = bpsToWad(bidBps);
        uint256 newAsk = bpsToWad(askBps);

        bidFee = wmul(alpha, newBid) + wmul(WAD - alpha, lastBid);
        askFee = wmul(alpha, newAsk) + wmul(WAD - alpha, lastAsk);

        if (carryBps > 0) {
            uint256 c = bpsToWad(carryBps);
            bidFee += c;
            askFee += c;
        }

        bidFee = _clampFeeRange(bidFee);
        askFee = _clampFeeRange(askFee);

        slots[0] = trade.timestamp;
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
        slots[14] = firstArbEwma;
        slots[15] = carryBps;
        slots[16] = noArbSteps;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_v6_auction";
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
