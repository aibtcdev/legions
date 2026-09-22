import { calculatePayout } from '../scripts/payout';

describe('Payout calculation', () => {
  it('matches the example from the README', () => {
    const result = calculatePayout({
      poolSats: 30_000_000,
      drawPercent: 0.005,          // 0.5%
      totalSignals: 84,
      proposerFeePercent: 0.01,    // 1%
      bondBps: 5,                  // 5 bps
    });

    expect(result.draw).toBe(150_000);
    expect(result.bond).toBe(15_000);
    expect(result.proposerFee).toBe(1_500);
    expect(result.distributable).toBe(148_500);
    expect(result.perSignal).toBe(1_767);
  });
});
