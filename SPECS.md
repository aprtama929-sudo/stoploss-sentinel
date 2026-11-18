# Reactive Omni Buildathon — Specs & Design

Researched 2026-11-11 from official sources:
- Announcement / track specs: https://blog.reactive.network/reactive-omni-buildathon-thirty-days-to-find-out-what-one-second-buys/ (published 2026-11-04)
- Registration & submission: DoraHacks hackathon page "Reactive Omni Buildathon" (page blocks text fetchers with HTTP 405; the checklist below is quoted from Reactive's own announcement, which describes the DoraHacks submission fields)
- Developer docs: https://dev.reactive.network/ (Getting Started, Reactive Contracts, Callback Contracts, Economy, Reactive Mainnet & Lasna Testnet, Origins & Destinations)
- Library: https://github.com/Reactive-Network/reactive-lib-omni (imports `@reactive/src/...`)

## Event facts

- Runs **November 5 – December 5, 2026**. Submissions close **5 Dec 2026**.
- **$5,500 total prizes, denominated in USD, paid in REACT.**
- Three tracks:
  - *Every Second Counts* — high-frequency DeFi automation on Unichain Sepolia / Base Sepolia with Lasna in the middle. $2,000 / $250.
  - *Set It and Forget It* — personal automations, any chain Reactive supports. **$2,000 / $250. ← OUR TRACK**
  - *Reactive Meets AI* — an AI model must be part of the running system. $1,000. ("Projects where AI only helped you build belong in **Set It and Forget It**.")
- "Set It and Forget It" track text (verbatim): "This track is for personal automations anyone can build, on any chain Reactive supports. AI coding tools have made it realistic for people who've never written a contract to build one that does something useful for them. Think of a portfolio tracker, an alert when a liquidity position hits a price, or custom rebalancing rules. Speed matters less here than usefulness. The question to ask is simple: is this something you'd actually leave running?"

## Deliverable checklist (VERBATIM from the official announcement)

> "Register on DoraHacks and pick a track. When you submit, include **a link to your public repository, your deployed contract addresses, a few transaction hashes showing the full loop from origin event to callback, and a demo video under three minutes**."

Ground rules (verbatim from the announcement):

> - "**Every Second Counts** runs on Lasna testnet. The other two tracks can use Reactive mainnet or Lasna."
> - "Repositories need to be public and open-source by the time you submit."
> - "Everything should be built during the event. Prior work can come in as a dependency, but not as the submission itself."
> - "On Base Sepolia, use timestamps rather than block counts for timers, cooldowns, or deadlines."

## Judging rubric (verbatim)

> "Every entry is scored from 1 to 5 on four equally weighted criteria:
> - **Execution:** Does it run? We want to see the reactive transactions and the callbacks they trigger on-chain. Entries without them aren't scored further.
> - **Integration:** Does the reactive contract do real work, or is it bolted on?
> - **Usefulness:** Does it solve a problem real users have?
> - **Craft:** Readable code, a working demo, and documentation someone else could follow.
> Entries are judged by Reactive team."

## Network / protocol parameters (from dev.reactive.network)

- **Lasna testnet:** RPC `https://lasna-rpc.rnk.dev`, chain ID **5318007**, currency **lREACT**, explorer **https://lasna.reactscan.net**
- **System contract (mainnet & Lasna):** `0x8888888888888888888888888888888888888888`
- **Ethereum Sepolia:** chain ID 11155111, origin ✅ destination ✅, **callback proxy `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`**
- **Reactive faucet:** send Sepolia ETH to faucet contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (Ethereum Sepolia) — **1 ETH → 100 lREACT**, or call `request(address)` with value, e.g. `--value 0.1ether` → 10 lREACT.
- **RSC model (Omni):** ordinary contract inheriting `AbstractReactive`; constructor calls `SYSTEM.subscribe(chainId, contract, topic0, topic1..3)` (wildcards = `REACTIVE_IGNORE`); network calls `react(LogRecord)` (guard `onlySystem`); callbacks via `SYSTEM.requestCallbackV_1_0({chainId, recipient, gasLimit, payload})` — **payload's first argument must be an `address` placeholder (`address(0)`)**, overwritten by the network with the requesting RSC's address.
- **Callback side:** destination contract inherits `AbstractCallback(callbackProxy, rscAddress)`; callback method guarded by `onlyServiceProvider` + `onlyCallbackSender(firstArg)`.
- **Economy:** RSC pays for `react()` executions in lREACT from its own balance/reserves (payable constructor + `SYSTEM.depositTo(rsc)` reserves); callback recipient pays for callback delivery in the destination chain's native token (fund at deployment + `proxy.depositTo(contract)`). Any debt > 0 halts execution. Minimum callback gas limit 100,000; reactive tx gas cap 900,000.
- **Deploy order:** (1) deploy RSC on Lasna, (2) deploy callback contract on Sepolia with (proxy, RSC address), (3) set recipient on the RSC via owner-only setter, (4) fund both sides.

## Design — "StopLoss Sentinel" (Set It and Forget It)

**What it automates.** A user opens a position in `SentinelVault` on Ethereum Sepolia (deposits test ETH, sets a stop-loss floor price once) and walks away. The vault's price is published by an owner-operated feed function that emits `PriceUpdated(price)` (standing in for any real oracle/DEX TWAP in production). The `StopLossSentinel` reactive contract on Lasna subscribes to `PriceUpdated` for that vault. Inside `react()` it does the real work: it compares the reported price against the vault's floor, ignores non-breaching updates, and — only on a breach — requests a callback to the vault on Sepolia. The callback (delivered by the network through the Sepolia callback proxy, authenticated by both `onlyServiceProvider` and `onlyCallbackSender`) closes the position and refunds the full balance to the user automatically. One setup transaction; the protection then runs unattended forever, with no keeper bot, no polling, and nobody's server to keep alive.

## Connectivity diagnosis — Lasna RPC from the build VM (2026-11-11, 01:24–02:55 UTC)

- `https://lasna-rpc.rnk.dev` is the ONLY Lasna RPC in the official docs and in chainid.network (chain 5318007). The pre-Omni host `https://lasna-omni-rpc.rnk.dev` (May 2026 testnet post) is stale.
- From this VM (egress via the Hatch proxy): DNS resolves; HTTPS **GET /** returns `200 OK` in ~1 s with header `X-Erpc-Version: 0.5.0` (an eRPC gateway health response, body `OK`).
- **Every JSON-RPC POST times out with zero bytes returned** — 20/20 background probe attempts over ~25 minutes plus all manual attempts (curl and Foundry `cast`, HTTP/1.1 and default, browser UA, alternate path style). WebSocket attempts return a corrupt-message error (proxy interference). The same tooling reaches Ethereum Sepolia and Base Sepolia public RPCs instantly, so the failure is specific to POST traffic toward `*.rnk.dev` through this egress path, not a general network outage.
- Consequence: contracts, tests, and deployment scripts are complete, but live deployment and the on-chain loop must run once either (a) this egress path passes POSTs to rnk.dev, or (b) the one-command script (`script/run_all.sh`) is run from an environment with normal access to the Lasna RPC. Funding the deployer wallet (Sepolia ETH faucet claim) is a browser step for Aditya regardless — see EVIDENCE.md.

**Why it fits the rubric.** *Execution:* the full origin-event → reactive-tx → callback-tx loop is visible on Reactscan/Sepolia explorers. *Integration:* the RSC is not a forwarder — it holds the decision (threshold comparison, breach latch so it fires exactly once per arming). *Usefulness:* stop-loss protection is the track's own example class ("an alert when a liquidity position hits a price" — except this one acts instead of just alerting), and it is exactly the kind of thing a user sets once and leaves running. *Craft:* two small, readable contracts plus a standard Foundry test suite and a scripted demo.
