// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // --- decay / update constants ---
    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 500; // ~20 bps of reserve
    uint256 constant DIR_DECAY = 800000000000000000; // 0.80
    uint256 constant ACT_DECAY = 700000000000000000; // 0.70
    uint256 constant SIZE_DECAY = 700000000000000000; // 0.70
    uint256 constant TOX_DECAY = 800000000000000000; // 0.80
    uint256 constant SIGMA_DECAY = 650000000000000000; // 0.65
    uint256 constant LAMBDA_DECAY = 996000000000000000; // 0.99
    uint256 constant SIZE_BLEND_DECAY = 650000000000000000; // 0.65
    uint256 constant TOX_BLEND_DECAY = 120000000000000000;
    uint256 constant ACT_BLEND_DECAY = 990500000000000000;
    uint256 constant PHAT_ALPHA = 280000000000000000; // 0.22
    uint256 constant PHAT_SHOCK_GATE = 40000000000000000;
    uint256 constant DIR_IMPACT_MULT = 2;

    // --- state caps ---
    uint256 constant RET_CAP = WAD / 10; // 10%
    uint256 constant TOX_CAP = WAD / 5; // 20%
    uint256 constant TRADE_RATIO_CAP = WAD / 5; // 20%
    uint256 constant LAMBDA_CAP = 5 * WAD; // max 5 trades/step estimate
    uint256 constant STEP_COUNT_CAP = 64; // guardrail

    // --- fee model constants ---
    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 200000000000000000; // 0.20
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 5600 * BPS;
    uint256 constant TOX_COEF = 300 * BPS;
    uint256 constant TOX_QUAD_COEF = 11700 * BPS;
    uint256 constant ACT_COEF = 53500 * BPS;
    uint256 constant DIR_COEF = 20 * BPS;
    uint256 constant DIR_TOX_COEF = 100 * BPS;
    uint256 constant STALE_DIR_COEF = 6900 * BPS;
    uint256 constant TAIL_KNEE = 500 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000; // 0.90
    uint256 constant FIRST_ARB_RATIO = WAD / 320; // ~31bps
    uint256 constant CONT_ARB_REBOUND = 9 * BPS;
    uint256 constant CONT_NORMAL_REBOUND = 3 * BPS;

    // slots[0] = bid fee
    // slots[1] = ask fee
    // slots[2] = last timestamp
    // slots[3] = dirState (centered at WAD, [0, 2*WAD])
    // slots[4] = actEma
    // slots[5] = pHat
    // slots[6] = sigmaHat
    // slots[7] = lambdaHat
    // slots[8] = sizeHat
    // slots[9] = toxEma
    // slots[10] = stepTradeCount (raw integer)
    // slots[11] = firstTradeArbish (0/1)

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD; // neutral direction
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 950000000000000; // 0.095% initial sigma guess
        slots[7] = 800000000000000000; // 0.8 initial arrival-rate guess
        slots[8] = 2000000000000000; // 0.2% reserve-size ratio guess
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pHat = slots[5];
        uint256 sigmaHat = slots[6];
        uint256 lambdaHat = slots[7];
        uint256 sizeHat = slots[8];
        uint256 toxEma = slots[9];
        uint256 stepTradeCount = slots[10];
        uint256 firstArbish = slots[11];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            // Decay multi-step memory.
            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));

            // Update arrival-rate estimate using how many fills we saw in the prior active step.
            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        if (pHat == 0) pHat = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        if (firstInStep) {
            uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
            if (ret <= PHAT_SHOCK_GATE) {
                pHat = wmul(pHat, WAD - PHAT_ALPHA) + wmul(pImplied, PHAT_ALPHA);
            }
            if (ret > RET_CAP) ret = RET_CAP;
            sigmaHat = wmul(sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
        }

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        if (firstInStep) {
            firstArbish = tradeRatio <= FIRST_ARB_RATIO ? 1 : 0;
        }

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > WAD / 4) push = WAD / 4;

            // isBuy=true => AMM buys X => sell pressure.
            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);

            sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeHat > WAD) sizeHat = WAD;
        }

        uint256 tox = pHat > 0 ? wdiv(absDiff(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        uint256 toxSignal = toxEma;

        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);
        uint256 fMid = fBase + wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxSignal, toxSignal)) + wmul(ACT_COEF, actEma);

        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        // Additional directional protection using stale-price sign.
        if (STALE_DIR_COEF > 0) {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
            if (spot >= pHat) {
                bidFee = bidFee + staleShift;
                askFee = askFee > staleShift ? askFee - staleShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
            }
        }

        bidFee = clampFee(_compressTail(bidFee));
        askFee = clampFee(_compressTail(askFee));

        if (!firstInStep) {
            uint256 rebate = firstArbish == 1 ? CONT_ARB_REBOUND : CONT_NORMAL_REBOUND;
            bidFee = bidFee > rebate ? (bidFee - rebate) : 0;
            askFee = askFee > rebate ? (askFee - rebate) : 0;
            bidFee = clampFee(bidFee);
            askFee = clampFee(askFee);
        }

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pHat;
        slots[6] = sigmaHat;
        slots[7] = lambdaHat;
        slots[8] = sizeHat;
        slots[9] = toxEma;
        slots[10] = stepTradeCount;
        slots[11] = firstArbish;

        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, TAIL_SLOPE);
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if ((exp & 1) == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function getName() external pure override returns (string memory) {
        return "BandShield_ghost_rebound";
    }
}
