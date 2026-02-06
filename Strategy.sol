// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                                TUNING
    //////////////////////////////////////////////////////////////*/

    // Baseline and dynamic bounds (WAD bps units).
    uint256 private constant LOW_FEE = 50 * BPS;
    uint256 private constant MIN_DYNAMIC_FEE = 45 * BPS;
    uint256 private constant MAX_DYNAMIC_FEE = 80 * BPS;

    // Toxicity state drives fee regime.
    uint256 private constant TOX_CAP = 140 * BPS;
    uint256 private constant TOX_RATIO_DIV = 7; // tox += tradeRatio / 7
    uint256 private constant TOX_TO_FEE_DIV = 2; // fee += tox / 2
    uint256 private constant TRADE_DECAY = 2 * BPS;
    uint256 private constant TIME_DECAY_PER_STEP = 1 * BPS;
    uint256 private constant STREAK_BONUS = 2 * BPS;

    // Trade-size buckets (in fraction of reserveY).
    uint256 private constant BIG_RATIO = 150 * BPS; // 1.5%
    uint256 private constant SHOCK_RATIO = 250 * BPS; // 2.5%
    uint256 private constant BIG_BUMP = 4 * BPS;
    uint256 private constant SHOCK_SIDE_BUMP = 10 * BPS;
    uint256 private constant SHOCK_TOX_BUMP = 20 * BPS;

    // Side + inventory skewing.
    uint256 private constant SIDE_TILT = 4 * BPS;
    uint256 private constant SIDE_RELIEF = 1 * BPS;
    uint256 private constant INV_THRESHOLD = 200 * BPS; // 2.0% of initial X
    uint256 private constant INV_TILT_UP = 3 * BPS;
    uint256 private constant INV_RELIEF = 2 * BPS;
    uint256 private constant MAX_SPREAD = 24 * BPS;

    // Per-step phase detector.
    uint256 private constant INTRASTEP_REBATE = 0 * BPS;
    uint256 private constant INTRASTEP_TOX_LIMIT = 90 * BPS;

    // Short-horizon volatility proxy and post-arb cooldown mode.
    uint256 private constant VOL_CAP = 180 * BPS;
    uint256 private constant VOL_TO_FEE_DIV = 12; // fee += vol / 12
    uint256 private constant JUMP_TO_VOL_DIV = 2; // vol input includes jump/2
    uint256 private constant COOLDOWN_TRADES = 2;
    uint256 private constant COOLDOWN_TRIGGER_RATIO = 180 * BPS; // 1.8%
    uint256 private constant COOLDOWN_VOL_TRIGGER = 110 * BPS;
    uint256 private constant COOLDOWN_SIDE_BUMP = 5 * BPS;
    uint256 private constant COOLDOWN_BASE_BUMP = 4 * BPS;

    /*//////////////////////////////////////////////////////////////
                              SLOT LAYOUT
    //////////////////////////////////////////////////////////////*/

    // slots[0] = current bid fee
    // slots[1] = current ask fee
    // slots[2] = toxicity score
    // slots[3] = last side (1 = isBuy true, 2 = isBuy false)
    // slots[4] = same-side streak count
    // slots[5] = last timestamp
    // slots[6] = initial reserveX
    // slots[7] = number of trades seen in the current timestamp
    // slots[8] = short-horizon volatility EMA (WAD ratio)
    // slots[9] = cooldown trades remaining
    // slots[10] = last implied trade price (WAD Y/X)
    function afterInitialize(uint256 initialX, uint256) external override returns (uint256, uint256) {
        slots[0] = LOW_FEE;
        slots[1] = LOW_FEE;
        slots[2] = 0;
        slots[3] = 0;
        slots[4] = 0;
        slots[5] = 0;
        slots[6] = initialX;
        slots[7] = 0;
        slots[8] = 0;
        slots[9] = 0;
        slots[10] = 0;
        return (LOW_FEE, LOW_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBid = slots[0];
        uint256 prevAsk = slots[1];
        if (prevBid == 0) prevBid = LOW_FEE;
        if (prevAsk == 0) prevAsk = LOW_FEE;

        uint256 tox = slots[2];
        uint256 lastSide = slots[3];
        uint256 streak = slots[4];
        uint256 lastTimestamp = slots[5];
        uint256 initialX = slots[6];
        uint256 vol = slots[8];
        uint256 cooldown = slots[9];
        uint256 lastImpliedPrice = slots[10];
        bool isNewStep = trade.timestamp > lastTimestamp;
        uint256 tradesThisStep = isNewStep ? 1 : (slots[7] + 1);
        slots[7] = tradesThisStep;

        // Update side streak.
        uint256 side = trade.isBuy ? 1 : 2;
        if (side == lastSide) {
            streak = streak + 1;
        } else {
            streak = 1;
        }
        slots[3] = side;
        slots[4] = streak;

        // Time decay for idle periods between trades.
        if (isNewStep) {
            uint256 dt = trade.timestamp - lastTimestamp;
            uint256 timeDecay = dt * TIME_DECAY_PER_STEP;
            tox = tox > timeDecay ? tox - timeDecay : 0;
        }
        slots[5] = trade.timestamp;

        // Per-trade decay.
        tox = tox > TRADE_DECAY ? tox - TRADE_DECAY : 0;

        // Toxic flow estimator from trade size.
        uint256 tradeRatio = trade.reserveY == 0 ? 0 : wdiv(trade.amountY, trade.reserveY);
        uint256 impliedPrice = trade.amountX == 0 ? 0 : wdiv(trade.amountY, trade.amountX);
        uint256 jumpRatio = 0;
        if (lastImpliedPrice > 0 && impliedPrice > 0) {
            jumpRatio = wdiv(absDiff(impliedPrice, lastImpliedPrice), lastImpliedPrice);
        }
        slots[10] = impliedPrice;

        // Short-horizon vol proxy: EMA of trade size + price jump.
        uint256 volInput = tradeRatio + (jumpRatio / JUMP_TO_VOL_DIV);
        vol = (7 * vol + volInput) / 8;
        if (vol > VOL_CAP) vol = VOL_CAP;
        slots[8] = vol;

        tox += tradeRatio / TOX_RATIO_DIV;
        if (streak >= 3) {
            tox += (streak - 2) * STREAK_BONUS;
        }
        if (tradeRatio > SHOCK_RATIO) {
            tox += SHOCK_TOX_BUMP;
        }
        if (tox > TOX_CAP) tox = TOX_CAP;
        slots[2] = tox;

        // Opening-trade toxicity trigger for short cooldown mode.
        if (isNewStep) {
            if (tradeRatio > COOLDOWN_TRIGGER_RATIO || (tradeRatio > BIG_RATIO && vol > COOLDOWN_VOL_TRIGGER)) {
                cooldown = COOLDOWN_TRADES;
            } else if (cooldown > 0) {
                cooldown = cooldown - 1;
            }
        } else if (cooldown > 0) {
            cooldown = cooldown - 1;
        }
        slots[9] = cooldown;

        // Target mid-fee from regime state.
        uint256 target = LOW_FEE + (tox / TOX_TO_FEE_DIV) + (vol / VOL_TO_FEE_DIV);
        target = _clampRange(target);
        uint256 bid = target;
        uint256 ask = target;

        // Side-sensitive skew.
        if (trade.isBuy) {
            // AMM bought X: protect bid side.
            bid += SIDE_TILT;
            ask = ask > SIDE_RELIEF ? ask - SIDE_RELIEF : 0;
        } else {
            // AMM sold X: protect ask side.
            ask += SIDE_TILT;
            bid = bid > SIDE_RELIEF ? bid - SIDE_RELIEF : 0;
        }

        // Inventory skew relative to initial X reserve.
        if (initialX > 0) {
            uint256 xBand = wmul(initialX, INV_THRESHOLD);
            uint256 upper = initialX + xBand;
            uint256 lower = initialX > xBand ? initialX - xBand : 0;
            if (trade.reserveX > upper) {
                // Long X: discourage more X-in, encourage X-out.
                bid += INV_TILT_UP;
                ask = ask > INV_RELIEF ? ask - INV_RELIEF : 0;
            } else if (trade.reserveX < lower) {
                // Short X: discourage more X-out, encourage X-in.
                ask += INV_TILT_UP;
                bid = bid > INV_RELIEF ? bid - INV_RELIEF : 0;
            }
        }

        // Size-triggered extra bump.
        if (tradeRatio > SHOCK_RATIO) {
            if (trade.isBuy) {
                bid += SHOCK_SIDE_BUMP;
            } else {
                ask += SHOCK_SIDE_BUMP;
            }
        } else if (tradeRatio > BIG_RATIO) {
            if (trade.isBuy) {
                bid += BIG_BUMP;
            } else {
                ask += BIG_BUMP;
            }
        }

        // Asymmetric smoothing: rise quickly into risk, decay slower out of it.
        if (tradeRatio <= SHOCK_RATIO) {
            if (bid > prevBid) {
                bid = bid;
            } else {
                bid = (6 * prevBid + bid) / 7;
            }
            if (ask > prevAsk) {
                ask = ask;
            } else {
                ask = (6 * prevAsk + ask) / 7;
            }
        }

        if (cooldown > 0) {
            bid += COOLDOWN_BASE_BUMP;
            ask += COOLDOWN_BASE_BUMP;
            uint256 sideBump = tradeRatio > SHOCK_RATIO ? (COOLDOWN_SIDE_BUMP + BPS) : COOLDOWN_SIDE_BUMP;
            if (trade.isBuy) {
                bid += sideBump;
            } else {
                ask += sideBump;
            }
        }

        // Step-phase logic:
        // - First trade in step is often informed; keep a side-specific guard.
        // - Later same-step flow is more likely retail; rebate to win routing share.
        if (
            !isNewStep &&
            cooldown == 0 &&
            tradesThisStep >= 2 &&
            tox < INTRASTEP_TOX_LIMIT &&
            tradeRatio <= BIG_RATIO
        ) {
            bid = bid > INTRASTEP_REBATE ? bid - INTRASTEP_REBATE : 0;
            ask = ask > INTRASTEP_REBATE ? ask - INTRASTEP_REBATE : 0;
        }

        // Bound fees and spread.
        bid = _clampRange(clampFee(bid));
        ask = _clampRange(clampFee(ask));

        if (bid > ask) {
            uint256 spread = bid - ask;
            if (spread > MAX_SPREAD) {
                bid = ask + MAX_SPREAD;
            }
        } else {
            uint256 spread = ask - bid;
            if (spread > MAX_SPREAD) {
                ask = bid + MAX_SPREAD;
            }
        }

        bid = _clampRange(clampFee(bid));
        ask = _clampRange(clampFee(ask));
        slots[0] = bid;
        slots[1] = ask;
        return (bid, ask);
    }

    function getName() external pure override returns (string memory) {
        return "V5_VolCooldown";
    }

    function _clampRange(uint256 fee) internal pure returns (uint256) {
        return clamp(fee, MIN_DYNAMIC_FEE, MAX_DYNAMIC_FEE);
    }
}
