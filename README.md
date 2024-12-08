# Surety Protocol Uniswap V4 Co-Pool Hook - ⚠️ WIP

> **⚠️ Warning:** This is early research work. It evaluates the viability of leveraging Uniswap V4 as the embedded AMM in the Surety Protocol.

## Description

The Co-Pool Hook is a Uniswap V4 Hook Smart Contract that enables liquidity providers to combine assets into a single position, with one side delegating liquidity management to the other. It improves AMM efficiency by supporting single-sided LP, optimising yield, deploying locked protocol capital into AMMs, and facilitating JIT rebalancing to reduce trading spreads.

## Goals/Features

- **Single-Sided Liquidity Support**: Allows liquidity providers to stake assets individually, reducing LP overhead for one-side of the Pool.
- **Delegated Liquidity Management**: Enables one side of the pool to manage liquidity for both parties, aligning incentives for active LP management.
- **Locked Capital Deployment**: Unlocks additional yield opportunities by deploying locked protocol capital into AMM pools.
- **JIT Rebalancing**: Aims to use just-in-time rebalancing to minimise trading spreads and enhance market efficiency.

## How It Works

1. The Co-Pool Hook aggregates liquidity from two parties into a single position.
2. One party can delegate liquidity management responsibilities to the other, who may earn additional rewards for active management.
3. The combined liquidity is used to generate yield within the AMM, with potential for JIT rebalancing to optimise spreads.
4. The hook facilitates real-time rebalancing of unmatched assets to reduce spreads and improve liquidity flow.

## Use Cases

- Protocols with locked capital can use the deploy their assets into a CoPool hook-enabled AMM, unlocking additional yield streams.
- Liquidity providers can delegate management tasks to experienced LP managers, ensuring optimal capital use.
- By reducing trading spreads and improving market depth, the Co-Pool Hook supports a more efficient trading ecosystem.

## Contributing

This project is in its early stages and contributions are welcome. Please submit issues or pull requests to help improve the Co-Pool Hook.

## License

Unlicensed rn...

## Contact

[Join our Discord](https://go.usher.so/discord)

