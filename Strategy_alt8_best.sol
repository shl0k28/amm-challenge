// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    uint256 private constant MIN_FEE_BPS = 7;
    uint256 private constant MAX_FEE_BPS = 954;
    uint256 private constant MAX_SPREAD_BPS = 915;

    uint256 private constant ARB_BASE_RATIO_WAD = 17 * BPS;
    uint256 private constant ARB_RATIO_DIV = 1;
    uint256 private constant ARB_SIGMA_DIV = 7;
    uint256 private constant ARB_MAX_CAP_WAD = 89 * BPS;
    uint256 private constant ALPHA_P = 36e16;
    uint256 private constant ALPHA_VAR = 23e16;
    uint256 private constant ALPHA_L = 13e16;
    uint256 private constant ALPHA_RATIO = 12e16;

    uint256 private constant SIGMA_MIN = 7 * BPS;
    uint256 private constant SIGMA_MAX = 24 * BPS;

    uint256 private constant SAFE_BASE_BPS = 1;
    uint256 private constant SAFE_VOL_MULT_BPS = 1892;
    uint256 private constant SAFE_LAMBDA_SWING_BPS = 8;
    uint256 private constant CALM_SIGMA = 9 * BPS;
    uint256 private constant CALM_LAMBDA = 34e16;
    uint256 private constant CALM_SAFE_SHIFT_BPS = 1;
    uint256 private constant CALM_VULN_SHIFT_BPS = 0;
    uint256 private constant STORM_SIGMA = 11 * BPS;
    uint256 private constant STORM_LAMBDA = 28e16;
    uint256 private constant STORM_SAFE_SHIFT_BPS = 0;
    uint256 private constant STORM_VULN_SHIFT_BPS = 0;

    uint256 private constant VULN_MIN_BPS = 51;
    uint256 private constant VULN_SIGMA_DIV = 16;
    uint256 private constant VULN_BUFFER_BPS = 1;

    uint256 private constant LAMBDA_REF = WAD / 3;
    uint256 private constant ARMOR_LAMBDA = WAD / 5;
    uint256 private constant ARMOR_SIGMA = 10 * BPS;
    uint256 private constant ARMOR_SAFE_FLOOR = 18;
    uint256 private constant ARMOR_VULN_FLOOR = 71;

    uint256 private constant INV_SENS_BPS = 108;
    uint256 private constant INV_MAX_SKEW_BPS = 47;

    uint256 private constant CONT_ARB_REBATE_BPS = 3;
    uint256 private constant CONT_TAIL_REBATE_BPS = 1;

    uint256 private constant SHOCK_RATIO_WAD = 89 * BPS;
    uint256 private constant SHOCK_BUMP_BPS = 4;
    uint256 private constant SHOCK_DECAY_BPS = 2;
    uint256 private constant SHOCK_MAX_BPS = 20;
    uint256 private constant STALE_STEP = 24;
    uint256 private constant STALE_SAFE_PER_BPS = 0;
    uint256 private constant STALE_VULN_PER_BPS = 0;
    uint256 private constant STALE_MAX_BPS = 0;
    uint256 private constant STALE_REBATE_GUARD_BPS = 1000;

    uint256 private constant ALPHA_SLOW = 79e16;
    uint256 private constant ALPHA_FAST = 100e16;

    // slots:
    // [0] lastTs
    // [2] lastBid
    // [3] lastAsk
    // [4] pHat
    // [5] lastFair
    // [6] var
    // [7] lambda
    // [8] shock
    // [9] stepTrades
    // [10] ratioEWMA
    // [11] lastArbTs

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 spot = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        uint256 start = bpsToWad(34);
        bidFee = start;
        askFee = start;

        slots[2] = bidFee;
        slots[3] = askFee;
        slots[4] = spot;
        slots[5] = spot;
        slots[6] = wmul(10 * BPS, 10 * BPS);
        slots[7] = LAMBDA_REF;
        slots[10] = 24 * BPS;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastTs = slots[0];
        uint256 lastBid = slots[2];
        uint256 lastAsk = slots[3];
        uint256 pHat = slots[4];
        uint256 lastFair = slots[5];
        uint256 varEWMA = slots[6];
        uint256 lambdaEWMA = slots[7];
        uint256 shockBps = slots[8];
        uint256 stepTrades = slots[9];
        uint256 ratioEWMA = slots[10];
        uint256 lastArbTs = slots[11];

        if (lastBid == 0) lastBid = bpsToWad(34);
        if (lastAsk == 0) lastAsk = bpsToWad(34);
        if (pHat == 0) pHat = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : 100 * WAD;
        if (lastFair == 0) lastFair = pHat;
        if (ratioEWMA == 0) ratioEWMA = 24 * BPS;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        bool firstInStep = trade.timestamp != lastTs;

        if (firstInStep && lastTs > 0 && trade.timestamp > lastTs) {
            uint256 dt = trade.timestamp - lastTs;
            uint256 inst = WAD / dt;
            lambdaEWMA = _ewma(lambdaEWMA, inst, ALPHA_L);
        }

        uint256 sigma = sqrt(varEWMA * WAD);
        if (sigma < SIGMA_MIN) sigma = SIGMA_MIN;
        if (sigma > SIGMA_MAX) sigma = SIGMA_MAX;
        uint256 sigmaBps = sigma / BPS;

        uint256 arbCap = ARB_BASE_RATIO_WAD + (ratioEWMA / ARB_RATIO_DIV) + (sigma / ARB_SIGMA_DIV);
        if (arbCap > ARB_MAX_CAP_WAD) arbCap = ARB_MAX_CAP_WAD;
        bool likelyArb = firstInStep && (tradeRatio <= arbCap);
        stepTrades = firstInStep ? 1 : (stepTrades + 1);

        if (likelyArb) {
            uint256 feeApplied = trade.isBuy ? lastBid : lastAsk;
            uint256 gamma = feeApplied < WAD ? (WAD - feeApplied) : 1;
            uint256 pEst = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            pHat = _ewma(pHat, pEst, ALPHA_P);

            uint256 ratio = lastFair > 0 ? wdiv(pEst, lastFair) : WAD;
            uint256 diff = ratio > WAD ? (ratio - WAD) : (WAD - ratio);
            varEWMA = _ewma(varEWMA, wmul(diff, diff), ALPHA_VAR);
            lastFair = pEst;
            lastArbTs = trade.timestamp;
        } else {
            pHat = _ewma(pHat, spot, 5e16);
        }

        if (shockBps > SHOCK_DECAY_BPS) shockBps -= SHOCK_DECAY_BPS;
        else shockBps = 0;
        if (tradeRatio >= SHOCK_RATIO_WAD) {
            if (shockBps + SHOCK_BUMP_BPS > SHOCK_MAX_BPS) shockBps = SHOCK_MAX_BPS;
            else shockBps += SHOCK_BUMP_BPS;
        }

        ratioEWMA = _ewma(ratioEWMA, tradeRatio, ALPHA_RATIO);

        uint256 safeBps = SAFE_BASE_BPS + ((sigma * SAFE_VOL_MULT_BPS) / WAD) + shockBps;
        if (lambdaEWMA > 0) {
            if (lambdaEWMA >= LAMBDA_REF) {
                uint256 ex = wdiv(lambdaEWMA, LAMBDA_REF) - WAD;
                uint256 tight = (ex * SAFE_LAMBDA_SWING_BPS) / WAD;
                if (tight > SAFE_LAMBDA_SWING_BPS) tight = SAFE_LAMBDA_SWING_BPS;
                safeBps = tight < safeBps ? (safeBps - tight) : safeBps;
            } else {
                uint256 def = WAD - wdiv(lambdaEWMA, LAMBDA_REF);
                uint256 wid = (def * SAFE_LAMBDA_SWING_BPS) / WAD;
                if (wid > SAFE_LAMBDA_SWING_BPS) wid = SAFE_LAMBDA_SWING_BPS;
                safeBps += wid;
            }
        }
        bool calm = sigma <= CALM_SIGMA && lambdaEWMA >= CALM_LAMBDA;
        bool storm = sigma >= STORM_SIGMA && lambdaEWMA <= STORM_LAMBDA;
        if (calm) {
            safeBps = safeBps > CALM_SAFE_SHIFT_BPS ? (safeBps - CALM_SAFE_SHIFT_BPS) : MIN_FEE_BPS;
        } else if (storm) {
            safeBps += STORM_SAFE_SHIFT_BPS;
        }
        uint256 staleBps = 0;
        if (lastArbTs > 0 && trade.timestamp > lastArbTs && STALE_STEP > 0) {
            staleBps = (trade.timestamp - lastArbTs) / STALE_STEP;
            if (staleBps > STALE_MAX_BPS) staleBps = STALE_MAX_BPS;
            safeBps += staleBps * STALE_SAFE_PER_BPS;
        }
        if (safeBps < MIN_FEE_BPS) safeBps = MIN_FEE_BPS;

        uint256 vulnFloor = VULN_MIN_BPS + sigmaBps / VULN_SIGMA_DIV;
        if (calm) {
            vulnFloor = vulnFloor > CALM_VULN_SHIFT_BPS ? (vulnFloor - CALM_VULN_SHIFT_BPS) : MIN_FEE_BPS;
        } else if (storm) {
            vulnFloor += STORM_VULN_SHIFT_BPS;
        }
        vulnFloor += staleBps * STALE_VULN_PER_BPS;

        if (lambdaEWMA < ARMOR_LAMBDA && sigma > ARMOR_SIGMA) {
            if (safeBps < ARMOR_SAFE_FLOOR) safeBps = ARMOR_SAFE_FLOOR;
            if (vulnFloor < ARMOR_VULN_FLOOR) vulnFloor = ARMOR_VULN_FLOOR;
        }

        uint256 bidBps = safeBps;
        uint256 askBps = safeBps;

        if (pHat > 0) {
            if (spot < pHat) {
                uint256 spotOverFair = wdiv(spot, pHat);
                uint256 reqAsk = WAD > spotOverFair ? (WAD - spotOverFair) : 0;
                uint256 reqAskBps = (reqAsk / BPS) + VULN_BUFFER_BPS;
                if (reqAskBps < vulnFloor) reqAskBps = vulnFloor;
                askBps = reqAskBps;
            } else if (spot > pHat) {
                uint256 fairOverSpot = wdiv(pHat, spot);
                uint256 reqBid = WAD > fairOverSpot ? (WAD - fairOverSpot) : 0;
                uint256 reqBidBps = (reqBid / BPS) + VULN_BUFFER_BPS;
                if (reqBidBps < vulnFloor) reqBidBps = vulnFloor;
                bidBps = reqBidBps;
            }
        }

        if (trade.reserveX > 0 && trade.reserveY > 0 && pHat > 0) {
            uint256 k = trade.reserveX * trade.reserveY;
            uint256 xStar = sqrt(wdiv(k, pHat));
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

        if (firstInStep && likelyArb && shockBps == 0 && staleBps <= STALE_REBATE_GUARD_BPS) {
            bidBps = bidBps > CONT_ARB_REBATE_BPS ? (bidBps - CONT_ARB_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > CONT_ARB_REBATE_BPS ? (askBps - CONT_ARB_REBATE_BPS) : MIN_FEE_BPS;
        } else if (!firstInStep && stepTrades >= 2 && shockBps == 0 && staleBps <= STALE_REBATE_GUARD_BPS) {
            bidBps = bidBps > CONT_TAIL_REBATE_BPS ? (bidBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;
            askBps = askBps > CONT_TAIL_REBATE_BPS ? (askBps - CONT_TAIL_REBATE_BPS) : MIN_FEE_BPS;
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
        slots[9] = stepTrades;
        slots[10] = ratioEWMA;
        slots[11] = lastArbTs;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_asymm";
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
