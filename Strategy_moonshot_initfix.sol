// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @notice Multi-timescale + hazard-state + PI-share controller on top of arb-implied fair inference.
contract Strategy is AMMStrategyBase {
    uint256 private constant MIN_FEE_BPS = 5;
    uint256 private constant MAX_FEE_BPS = 954;
    uint256 private constant MAX_SPREAD_BPS = 920;

    uint256 private constant NORMALIZER_BPS = 30;

    uint256 private constant ARB_BASE_RATIO_WAD = 16 * BPS;
    uint256 private constant ARB_RATIO_DIV = 2;
    uint256 private constant ARB_SIGMA_DIV = 8;
    uint256 private constant ARB_MAX_CAP_WAD = 92 * BPS;
    uint256 private constant MISALIGN_DIV = 2;

    uint256 private constant ALPHA_P_FAST = 44e16;
    uint256 private constant ALPHA_P_SLOW = 16e16;
    uint256 private constant ALPHA_RECENTER_FAST = 9e16;
    uint256 private constant ALPHA_RECENTER_SLOW = 4e16;

    uint256 private constant ALPHA_VAR_FAST = 28e16;
    uint256 private constant ALPHA_VAR_SLOW = 9e16;
    uint256 private constant ALPHA_VAR_FAST_DECAY = 4e16;
    uint256 private constant ALPHA_VAR_SLOW_DECAY = 1e16;

    uint256 private constant ALPHA_L_FAST = 24e16;
    uint256 private constant ALPHA_L_SLOW = 7e16;
    uint256 private constant ALPHA_L_ARB_DECAY = 6e16;
    uint256 private constant LAMBDA_REF = 33e16;

    uint256 private constant SIGMA_BLEND_FAST = 62e16;
    uint256 private constant SIGMA_MIN = 7 * BPS;
    uint256 private constant SIGMA_MAX = 24 * BPS;

    uint256 private constant ALPHA_RATIO = 12e16;

    uint256 private constant ALPHA_HAZ = 18e16;
    uint256 private constant HAZ_BASE = 22e16;
    uint256 private constant HAZ_SIGMA_WEIGHT = 26e16;
    uint256 private constant HAZ_LAMBDA_WEIGHT = 22e16;
    uint256 private constant HAZ_STALE_PER_STEP = 9e15;
    uint256 private constant HAZ_STALE_MAX = 24e16;
    uint256 private constant HAZ_OFFSIDE_STEP = 3e16;
    uint256 private constant HAZ_OFFSIDE_MAX = 18e16;
    uint256 private constant HAZ_ON = 64e16;
    uint256 private constant HAZ_OFF = 46e16;
    uint256 private constant OFFSIDE_CARRY_STREAK = 2;
    uint256 private constant MODE_ENTER_CONF = 2;
    uint256 private constant MODE_EXIT_CONF = 3;

    uint256 private constant MIS_THRESH_BPS = 18;
    uint256 private constant OFFSIDE_SENS_BPS = 2;
    uint256 private constant OFFSIDE_MAX_BPS = 72;

    uint256 private constant BASE_COMP_BPS = 18;
    uint256 private constant MIN_COMP_BPS = 4;
    uint256 private constant MAX_COMP_BPS = 38;
    uint256 private constant BASE_CARRY_BPS = 39;
    uint256 private constant HAZARD_TO_BPS = 26;
    uint256 private constant VOL_MULT_BPS = 10600;

    uint256 private constant PI_TARGET_LAMBDA = 34e16;
    uint256 private constant PI_KP_BPS = 22;
    uint256 private constant PI_KI_BPS = 5;
    uint256 private constant PI_ERR_DIV = 2;
    uint256 private constant PI_MAX_BPS = 18;
    uint256 private constant PI_I_MAX = 3e18;
    uint256 private constant PI_I_BIAS = 3e18;

    uint256 private constant VULN_MIN_BPS = 46;
    uint256 private constant VULN_SIGMA_DIV = 12;
    uint256 private constant VULN_BUFFER_BPS = 1;

    uint256 private constant SAFE_REBATE_BPS = 8;

    uint256 private constant INV_SENS_BPS = 103;
    uint256 private constant INV_MAX_SKEW_BPS = 52;

    uint256 private constant BIG_RATIO_WAD = 58 * BPS;
    uint256 private constant SHOCK_RATIO_WAD = 96 * BPS;
    uint256 private constant BIG_BUMP_BPS = 3;
    uint256 private constant SHOCK_BUMP_BPS = 8;
    uint256 private constant SHOCK_DECAY_BPS = 1;
    uint256 private constant SHOCK_MAX_BPS = 22;

    uint256 private constant CONT_ARB_REBATE_BPS = 3;
    uint256 private constant CONT_TAIL_REBATE_BPS = 3;

    uint256 private constant ALPHA_SLOW = 79e16;
    uint256 private constant ALPHA_FAST = 100e16;

    // slot layout (22 used)
    // [0]  lastSeenTs
    // [1]  lastRetailTs
    // [2]  lastBidFee
    // [3]  lastAskFee
    // [4]  pHatFast
    // [5]  pHatSlow
    // [6]  lastFair
    // [7]  varFast
    // [8]  varSlow
    // [9]  lambdaFast
    // [10] lambdaSlow
    // [11] shockBps
    // [12] ratioEWMA
    // [13] lastArbTs
    // [14] hazardEWMA
    // [15] mode (0 compete, 1 carry)
    // [16] modeConf
    // [17] errIntRaw (biased)
    // [18] offsideStreak
    // [19] stepTrades
    // [20] retailStreakDir
    // [21] retailStreakLen

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 spot = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        bidFee = bpsToWad(34);
        askFee = bpsToWad(34);

        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = spot;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastSeenTs = slots[0];
        uint256 lastRetailTs = slots[1];
        uint256 lastBid = slots[2];
        uint256 lastAsk = slots[3];
        uint256 pHatFast = slots[4];
        uint256 pHatSlow = slots[5];
        uint256 lastFair = slots[6];
        uint256 varFast = slots[7];
        uint256 varSlow = slots[8];
        uint256 lambdaFast = slots[9];
        uint256 lambdaSlow = slots[10];
        uint256 shockBps = slots[11];
        uint256 ratioEWMA = slots[12];
        uint256 lastArbTs = slots[13];
        uint256 hazardEWMA = slots[14];
        uint256 mode = slots[15];
        uint256 modeConf = slots[16];
        uint256 errIntRaw = slots[17];
        uint256 offsideStreak = slots[18];
        uint256 stepTrades = slots[19];
        uint256 retailStreakDir = slots[20];
        uint256 retailStreakLen = slots[21];

        if (lastBid == 0) lastBid = bpsToWad(34);
        if (lastAsk == 0) lastAsk = bpsToWad(34);
        if (pHatFast == 0) pHatFast = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : 100 * WAD;
        if (pHatSlow == 0) pHatSlow = pHatFast;
        if (lastFair == 0) lastFair = pHatSlow;
        if (varFast == 0) varFast = wmul(10 * BPS, 10 * BPS);
        if (varSlow == 0) varSlow = varFast;
        if (lambdaFast == 0) lambdaFast = LAMBDA_REF;
        if (lambdaSlow == 0) lambdaSlow = LAMBDA_REF;
        if (ratioEWMA == 0) ratioEWMA = 24 * BPS;
        if (hazardEWMA == 0) hazardEWMA = 58e16;
        if (errIntRaw == 0) errIntRaw = PI_I_BIAS;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHatSlow;
        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        bool firstInStep = trade.timestamp != lastSeenTs;
        stepTrades = firstInStep ? 1 : (stepTrades + 1);

        uint256 sigmaFast0 = sqrt(varFast * WAD);
        uint256 sigmaSlow0 = sqrt(varSlow * WAD);
        uint256 sigma0 = _blend(sigmaFast0, sigmaSlow0, SIGMA_BLEND_FAST);
        if (sigma0 < SIGMA_MIN) sigma0 = SIGMA_MIN;
        if (sigma0 > SIGMA_MAX) sigma0 = SIGMA_MAX;

        uint256 arbCap = ARB_BASE_RATIO_WAD + (ratioEWMA / ARB_RATIO_DIV) + (sigma0 / ARB_SIGMA_DIV);
        if (arbCap > ARB_MAX_CAP_WAD) arbCap = ARB_MAX_CAP_WAD;
        bool aligned = (spot == pHatSlow) || (spot < pHatSlow && !trade.isBuy) || (spot > pHatSlow && trade.isBuy);
        bool likelyArb = firstInStep && (tradeRatio <= arbCap) && (aligned || tradeRatio <= arbCap / MISALIGN_DIV);

        if (likelyArb) {
            uint256 feeApplied = trade.isBuy ? lastBid : lastAsk;
            uint256 gamma = feeApplied < WAD ? (WAD - feeApplied) : 1;
            uint256 pEst = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);

            pHatFast = _ewma(pHatFast, pEst, ALPHA_P_FAST);
            pHatSlow = _ewma(pHatSlow, pEst, ALPHA_P_SLOW);

            uint256 ratio = lastFair > 0 ? wdiv(pEst, lastFair) : WAD;
            uint256 diff = ratio > WAD ? (ratio - WAD) : (WAD - ratio);
            uint256 sq = wmul(diff, diff);
            varFast = _ewma(varFast, sq, ALPHA_VAR_FAST);
            varSlow = _ewma(varSlow, sq, ALPHA_VAR_SLOW);
            lastFair = pEst;
            lastArbTs = trade.timestamp;

            lambdaFast = _ewma(lambdaFast, lambdaSlow, ALPHA_L_ARB_DECAY);
            if (retailStreakLen > 0) retailStreakLen -= 1;
        } else {
            pHatFast = _ewma(pHatFast, spot, ALPHA_RECENTER_FAST);
            pHatSlow = _ewma(pHatSlow, pHatFast, ALPHA_RECENTER_SLOW);

            varFast = wmul(varFast, WAD - ALPHA_VAR_FAST_DECAY);
            varSlow = wmul(varSlow, WAD - ALPHA_VAR_SLOW_DECAY);

            if (lastRetailTs > 0 && trade.timestamp > lastRetailTs) {
                uint256 dtRetail = trade.timestamp - lastRetailTs;
                uint256 instLambda = WAD / dtRetail;
                lambdaFast = _ewma(lambdaFast, instLambda, ALPHA_L_FAST);
                lambdaSlow = _ewma(lambdaSlow, instLambda, ALPHA_L_SLOW);
            }
            lastRetailTs = trade.timestamp;

            uint256 side = trade.isBuy ? 1 : 2;
            if (side == retailStreakDir) {
                retailStreakLen += 1;
            } else {
                retailStreakDir = side;
                retailStreakLen = 1;
            }
        }

        ratioEWMA = _ewma(ratioEWMA, tradeRatio, ALPHA_RATIO);

        if (shockBps > SHOCK_DECAY_BPS) shockBps -= SHOCK_DECAY_BPS;
        else shockBps = 0;
        if (tradeRatio >= SHOCK_RATIO_WAD) {
            shockBps = shockBps + SHOCK_BUMP_BPS;
            if (shockBps > SHOCK_MAX_BPS) shockBps = SHOCK_MAX_BPS;
        } else if (tradeRatio >= BIG_RATIO_WAD) {
            shockBps = shockBps + BIG_BUMP_BPS;
            if (shockBps > SHOCK_MAX_BPS) shockBps = SHOCK_MAX_BPS;
        }

        uint256 sigmaFast = sqrt(varFast * WAD);
        uint256 sigmaSlow = sqrt(varSlow * WAD);
        uint256 sigma = _blend(sigmaFast, sigmaSlow, SIGMA_BLEND_FAST);
        if (sigma < SIGMA_MIN) sigma = SIGMA_MIN;
        if (sigma > SIGMA_MAX) sigma = SIGMA_MAX;
        uint256 sigmaBps = sigma / BPS;

        uint256 misBps = 0;
        if (pHatSlow > 0) {
            uint256 mis = spot >= pHatSlow ? wdiv(spot - pHatSlow, pHatSlow) : wdiv(pHatSlow - spot, pHatSlow);
            misBps = mis / BPS;
        }

        if (misBps > MIS_THRESH_BPS) {
            offsideStreak += 1;
            if (offsideStreak > 20) offsideStreak = 20;
        } else if (offsideStreak > 0) {
            offsideStreak -= 1;
        }

        uint256 hazardSample = HAZ_BASE;
        if (likelyArb) hazardSample += 42e16;
        else if (firstInStep) hazardSample += 20e16;

        if (sigma > SIGMA_MIN) {
            uint256 sigNorm = wdiv(sigma - SIGMA_MIN, SIGMA_MAX - SIGMA_MIN);
            hazardSample += wmul(sigNorm, HAZ_SIGMA_WEIGHT);
        }
        if (lambdaSlow < LAMBDA_REF) {
            uint256 lowNorm = wdiv(LAMBDA_REF - lambdaSlow, LAMBDA_REF);
            hazardSample += wmul(lowNorm, HAZ_LAMBDA_WEIGHT);
        }
        if (lastArbTs > 0 && trade.timestamp > lastArbTs) {
            uint256 stale = (trade.timestamp - lastArbTs) * HAZ_STALE_PER_STEP;
            if (stale > HAZ_STALE_MAX) stale = HAZ_STALE_MAX;
            hazardSample += stale;
        }
        if (offsideStreak > 0) {
            uint256 offsideHaz = offsideStreak * HAZ_OFFSIDE_STEP;
            if (offsideHaz > HAZ_OFFSIDE_MAX) offsideHaz = HAZ_OFFSIDE_MAX;
            hazardSample += offsideHaz;
        }
        if (hazardSample > WAD) hazardSample = WAD;
        hazardEWMA = _ewma(hazardEWMA, hazardSample, ALPHA_HAZ);

        bool wantCarry = hazardEWMA >= HAZ_ON || offsideStreak >= OFFSIDE_CARRY_STREAK;
        bool wantCompete = hazardEWMA <= HAZ_OFF && offsideStreak == 0;

        if (mode == 0) {
            if (wantCarry) {
                if (modeConf < MODE_ENTER_CONF) modeConf += 1;
                if (modeConf >= MODE_ENTER_CONF) {
                    mode = 1;
                    modeConf = 0;
                }
            } else if (modeConf > 0) {
                modeConf -= 1;
            }
        } else {
            if (wantCompete) {
                if (modeConf < MODE_EXIT_CONF) modeConf += 1;
                if (modeConf >= MODE_EXIT_CONF) {
                    mode = 0;
                    modeConf = 0;
                }
            } else if (modeConf > 0) {
                modeConf -= 1;
            }
        }

        int256 err = int256(PI_TARGET_LAMBDA) - int256(lambdaFast);
        int256 errInt = int256(errIntRaw) - int256(PI_I_BIAS);
        errInt += err / int256(PI_ERR_DIV);
        if (errInt > int256(PI_I_MAX)) errInt = int256(PI_I_MAX);
        if (errInt < -int256(PI_I_MAX)) errInt = -int256(PI_I_MAX);

        int256 piAdj = (int256(PI_KP_BPS) * err + int256(PI_KI_BPS) * errInt) / int256(WAD);
        if (piAdj > int256(PI_MAX_BPS)) piAdj = int256(PI_MAX_BPS);
        if (piAdj < -int256(PI_MAX_BPS)) piAdj = -int256(PI_MAX_BPS);
        errIntRaw = uint256(errInt + int256(PI_I_BIAS));

        uint256 volTermBps = (sigma * VOL_MULT_BPS) / WAD;
        uint256 hazardExtraBps = (hazardEWMA * HAZARD_TO_BPS) / WAD;

        uint256 baseBps;
        if (mode == 0) {
            int256 comp = int256(BASE_COMP_BPS + volTermBps + shockBps) - piAdj;
            if (comp < int256(MIN_COMP_BPS)) comp = int256(MIN_COMP_BPS);
            if (comp > int256(MAX_COMP_BPS)) comp = int256(MAX_COMP_BPS);
            baseBps = uint256(comp);
        } else {
            baseBps = BASE_CARRY_BPS + volTermBps + shockBps + hazardExtraBps;
            if (baseBps < NORMALIZER_BPS) baseBps = NORMALIZER_BPS;
        }

        uint256 bidBps = baseBps;
        uint256 askBps = baseBps;

        uint256 vulnFloor = VULN_MIN_BPS + (sigmaBps / VULN_SIGMA_DIV);
        if (mode == 1 && vulnFloor < NORMALIZER_BPS + 10) vulnFloor = NORMALIZER_BPS + 10;

        if (misBps > MIS_THRESH_BPS) {
            uint256 penalty = (misBps - MIS_THRESH_BPS) * OFFSIDE_SENS_BPS;
            if (penalty > OFFSIDE_MAX_BPS) penalty = OFFSIDE_MAX_BPS;
            if (spot < pHatSlow) askBps += penalty;
            else if (spot > pHatSlow) bidBps += penalty;
        }

        uint256 rebate = SAFE_REBATE_BPS;
        if (mode == 1) rebate = rebate / 2;
        if (hazardEWMA > HAZ_ON) rebate = rebate / 2;

        if (pHatSlow > 0) {
            if (spot < pHatSlow) {
                uint256 reqAskBps = misBps + VULN_BUFFER_BPS;
                if (reqAskBps < vulnFloor) reqAskBps = vulnFloor;
                if (askBps < reqAskBps) askBps = reqAskBps;
                bidBps = bidBps > rebate ? (bidBps - rebate) : MIN_FEE_BPS;
            } else if (spot > pHatSlow) {
                uint256 reqBidBps = misBps + VULN_BUFFER_BPS;
                if (reqBidBps < vulnFloor) reqBidBps = vulnFloor;
                if (bidBps < reqBidBps) bidBps = reqBidBps;
                askBps = askBps > rebate ? (askBps - rebate) : MIN_FEE_BPS;
            }
        }

        if (trade.reserveX > 0 && trade.reserveY > 0 && pHatSlow > 0) {
            uint256 k = trade.reserveX * trade.reserveY;
            uint256 xStar = sqrt(wdiv(k, pHatSlow));
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

        if (retailStreakLen >= 3) {
            uint256 streakBump = retailStreakLen - 2;
            if (streakBump > 6) streakBump = 6;
            if (retailStreakDir == 1) {
                bidBps += streakBump;
                askBps = askBps > (streakBump / 2) ? (askBps - (streakBump / 2)) : MIN_FEE_BPS;
            } else if (retailStreakDir == 2) {
                askBps += streakBump;
                bidBps = bidBps > (streakBump / 2) ? (bidBps - (streakBump / 2)) : MIN_FEE_BPS;
            }
        }

        if (firstInStep && likelyArb && shockBps == 0) {
            bidBps = bidBps > CONT_ARB_REBATE_BPS ? (bidBps - CONT_ARB_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > CONT_ARB_REBATE_BPS ? (askBps - CONT_ARB_REBATE_BPS) : MIN_FEE_BPS;
        } else if (!firstInStep && stepTrades >= 2 && shockBps == 0) {
            bidBps = bidBps > CONT_TAIL_REBATE_BPS ? (bidBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > CONT_TAIL_REBATE_BPS ? (askBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;
        }

        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);
        if (bidBps > askBps + MAX_SPREAD_BPS) bidBps = askBps + MAX_SPREAD_BPS;
        if (askBps > bidBps + MAX_SPREAD_BPS) askBps = bidBps + MAX_SPREAD_BPS;
        bidBps = _clampBps(bidBps);
        askBps = _clampBps(askBps);

        uint256 alpha = (likelyArb || tradeRatio >= SHOCK_RATIO_WAD || mode == 1) ? ALPHA_FAST : ALPHA_SLOW;
        uint256 newBid = bpsToWad(bidBps);
        uint256 newAsk = bpsToWad(askBps);

        bidFee = wmul(alpha, newBid) + wmul(WAD - alpha, lastBid);
        askFee = wmul(alpha, newAsk) + wmul(WAD - alpha, lastAsk);
        bidFee = _clampFeeRange(bidFee);
        askFee = _clampFeeRange(askFee);

        slots[0] = trade.timestamp;
        slots[1] = lastRetailTs;
        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = pHatFast;
        slots[5] = pHatSlow;
        slots[6] = lastFair;
        slots[7] = varFast;
        slots[8] = varSlow;
        slots[9] = lambdaFast;
        slots[10] = lambdaSlow;
        slots[11] = shockBps;
        slots[12] = ratioEWMA;
        slots[13] = lastArbTs;
        slots[14] = hazardEWMA;
        slots[15] = mode;
        slots[16] = modeConf;
        slots[17] = errIntRaw;
        slots[18] = offsideStreak;
        slots[19] = stepTrades;
        slots[20] = retailStreakDir;
        slots[21] = retailStreakLen;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_moonshot";
    }

    function _blend(uint256 a, uint256 b, uint256 wA) internal pure returns (uint256) {
        return wmul(a, wA) + wmul(b, WAD - wA);
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
