/**
 * Utility functions for calculating payouts in the News Legion contracts.
 *
 * These helpers are intentionally lightweight and pure so they can be used
 * both in the front‑end tooling and in unit tests to verify the on‑chain
 * logic.
 */

export interface PayoutParams {
  /** Total pool size in satoshis. */
  poolSats: number;
  /** Draw percentage (e.g., 0.005 for 0.5%). */
  drawPercent: number;
  /** Total number of signals for the week. */
  totalSignals: number;
  /** Proposer fee percentage of the draw (e.g., 0.01 for 1%). */
  proposerFeePercent: number;
  /** Bond in basis points (e.g., 5 for 5 bps). */
  bondBps: number;
}

/**
 * Calculates the payout breakdown for a given week.
 *
 * @param params - The parameters for the calculation.
 * @returns An object containing the draw, bond, proposer fee, distributable
 *          amount, and per‑signal payout.
 */
export function calculatePayout(params: PayoutParams) {
  const { poolSats, drawPercent, totalSignals, proposerFeePercent, bondBps } = params;

  // 0.5% of the pool is the draw
  const draw = Math.floor(poolSats * drawPercent);

  // 5 bps of the pool is the bond
  const bond = Math.floor(poolSats * bondBps / 10000);

  // 1% of the draw is the proposer fee
  const proposerFee = Math.floor(draw * proposerFeePercent);

  // Amount available for distribution after the proposer fee
  const distributable = draw - proposerFee;

  // Per‑signal payout (rounded down to the nearest satoshi)
  const perSignal = Math.floor(distributable / totalSignals);

  return {
    draw,
    bond,
    proposerFee,
    distributable,
    perSignal,
  };
}
