# StopLoss Sentinel

**A stop-loss you set once, and never think about again.**

StopLoss Sentinel is a personal automation built for the **Reactive Omni Buildathon — "Set It and Forget It" track**. Open a position, name the price that would hurt, and walk away. If the price ever crosses your floor, your position closes itself and the money comes back to your wallet — no keeper bot, no server to babysit, no "check the app every hour".

## How it works

```
Ethereum Sepolia                              Reactive Lasna                     Ethereum Sepolia
┌───────────────┐   PriceUpdated event   ┌──────────────────┐   callback    ┌───────────────┐
│ SentinelVault │ ─────────────────────► │ StopLossSentinel │ ─────────────► │ SentinelVault │
│  (position +  │   PositionOpened event │  (reactive       │  via callback │  closePosition│
│   price feed) │                        │   contract)      │     proxy     │  → refund     │
└───────────────┘                        └──────────────────┘               └───────────────┘
```

1. **You set it.** `SentinelVault.openPosition(floor)` on Sepolia — one deposit, one floor price. The vault emits `PositionOpened(amount, floor)`.
2. **The sentinel arms itself.** `StopLossSentinel` on Lasna is subscribed to the vault's events. The `PositionOpened` log teaches it your floor; it needs no configuration transaction from you.
3. **It watches every price update.** Each `PriceUpdated` log runs the sentinel's `react()`: above the floor, nothing happens. Below it, the sentinel latches (it will fire exactly once) and requests a callback through the Reactive system contract.
4. **It acts.** The network delivers the callback on Sepolia through the callback proxy. `closePosition` — callable only via that proxy and only for this sentinel (`onlyServiceProvider` + `onlyCallbackSender`) — unwinds the position and refunds the owner, retaining a small reserve so the contract can pay its own delivery fee.

The reactive contract does the deciding, not just forwarding: threshold comparison, arming from the position event, and a one-shot latch all live on-chain in `react()`.

In this testnet build the vault's price is published by its owner (`updatePrice`) as a stand-in for an oracle/TWAP feed; everything downstream of the price event is the production-shaped flow.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `StopLossSentinel` | Reactive Lasna (5318007) | Reactive contract: subscribes, decides, requests the callback |
| `SentinelVault` | Ethereum Sepolia (11155111) | Position + price feed; callback recipient that closes and refunds |

Built on the official [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni) (`AbstractReactive` / `AbstractCallback`), Solidity 0.8.29, Foundry.

## Deployment

The deployment is executed by `script/run_all.sh` (see below) once the deployer wallet is funded with Sepolia ETH; the resulting addresses and the full loop's transaction hashes are recorded here and in [EVIDENCE.md](EVIDENCE.md).

| Item | Value |
|---|---|
| StopLossSentinel (Lasna) | _TBD — pending deployment_ |
| SentinelVault (Sepolia) | _TBD — pending deployment_ |
| Origin tx — `openPosition` | _TBD_ |
| Origin tx — benign price update (120, no trigger) | _TBD_ |
| Origin tx — breaching price update (75) | _TBD_ |
| Reactive tx on Lasna (`StopLossTriggered`) | _TBD_ |
| Callback tx on Sepolia (`PositionClosed` + refund) | _TBD_ |

Explorers: Lasna https://lasna.reactscan.net · Sepolia https://sepolia.etherscan.io

## Run it

Requires [Foundry](https://book.getfoundry.sh/) (`forge` / `cast`).

```bash
forge test            # 11 tests: arming, guards, trigger latch, and the full
                      # loop end-to-end against mock system/proxy contracts

./script/run_all.sh fund    # Sepolia ETH -> lREACT via the official Reactive faucet contract
./script/run_all.sh deploy  # RSC on Lasna, vault on Sepolia, wire, fund, open position
./script/run_all.sh drive   # publish 120 (no-op), then 75 (breach) and watch it close itself
```

The deployer is a throwaway testnet-only wallet (`.testnet-wallet`, git-ignored, mode 600). Testnet funds only — the faucet, Lasna, and Sepolia are all test networks.

## Why "set it and forget it"

A stop-loss is the canonical personal automation: it is useless if it needs you awake at 3 a.m., and fragile if it runs on your laptop or a rented bot. Here the rule itself lives on-chain. It survives your laptop dying, your VPS expiring, and you forgetting the position exists — which is exactly the point.

## License

MIT
