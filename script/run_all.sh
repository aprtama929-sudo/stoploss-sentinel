#!/usr/bin/env bash
# StopLoss Sentinel — full lifecycle on public testnets.
#
#   Phase 1 (fund):    swap Sepolia ETH for lREACT via the official Reactive faucet contract
#   Phase 2 (deploy):  RSC on Lasna -> vault on Sepolia -> wire + fund reserves -> open position
#   Phase 3 (drive):   publish a benign price, then a breaching price, and wait for the
#                      network-delivered callback to close the position
#
# Usage:  ./script/run_all.sh [fund|deploy|drive|all]
# State is kept in deployments.env so phases can be re-run independently.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

# ---------- config ----------
SEPOLIA_RPC="${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev}"
SEPOLIA_CHAIN=11155111
LASNA_CHAIN=5318007
SYSTEM=0x8888888888888888888888888888888888888888
SEPOLIA_CALLBACK_PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
REACTIVE_FAUCET_SEPOLIA=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434

FAUCET_SWAP_ETH=0.10         # -> 10 lREACT at 1 ETH : 100 lREACT (RSC needs 3 deploy + 2 reserve = 5)
RSC_DEPLOY_LREACT=3          # lREACT sent with the RSC deployment (its execution balance)
RSC_RESERVE_LREACT=2         # lREACT deposited to the RSC's reserves
VAULT_DEPLOY_ETH=0.05        # Sepolia ETH sent with the vault deployment (callback fee balance)
VAULT_RESERVE_ETH=0.05       # Sepolia ETH deposited to the vault's reserves via the proxy
POSITION_ETH=0.05            # the demo position
FLOOR=100                    # stop-loss floor (feed price units)
PRICE_OK=120                 # benign price update (no trigger)
PRICE_BREACH=75              # breaching price update (triggers the callback)

WALLET_FILE=".testnet-wallet"
STATE="deployments.env"

PRIVATE_KEY="$(python3 -c "import json;print(json.load(open('$WALLET_FILE'))['data'][0]['private_key'])")"
DEPLOYER="$(python3 -c "import json;print(json.load(open('$WALLET_FILE'))['data'][0]['address'])")"
export PRIVATE_KEY
echo "Deployer: $DEPLOYER"

save_state() { grep -v "^$1=" "$STATE" 2>/dev/null > "$STATE.tmp" || true; echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
load_state() { [ -f "$STATE" ] && set -a && . "$STATE" && set +a || true; }

phase_fund() {
  local sep_bal lreact_bal
  sep_bal=$(cast balance "$DEPLOYER" --rpc-url "$SEPOLIA_RPC")
  lreact_bal=$(cast balance "$DEPLOYER" --rpc-url "$LASNA_RPC")
  echo "Sepolia ETH: $sep_bal wei | Lasna lREACT: $lreact_bal wei"
  if [ "$(echo "$lreact_bal < 5000000000000000000" | bc)" = "1" ]; then
    echo "Requesting lREACT from the Reactive faucet (sending $FAUCET_SWAP_ETH Sepolia ETH)..."
    cast send "$REACTIVE_FAUCET_SEPOLIA" "request(address)" "$DEPLOYER" \
      --value "${FAUCET_SWAP_ETH}ether" --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY"
    sleep 10
    echo "Lasna lREACT now: $(cast balance "$DEPLOYER" --rpc-url "$LASNA_RPC") wei"
  else
    echo "lREACT balance already sufficient, skipping faucet."
  fi
}

deploy_contract() { # $1=rpc $2=path:Name $3=value-ether, rest=args -> echoes address
  local rpc="$1" artifact="$2" value="$3"; shift 3
  forge create "$artifact" --broadcast --rpc-url "$rpc" --private-key "$PRIVATE_KEY" \
    --value "${value}ether" ${1:+--constructor-args "$@"} 2>/dev/null \
    | grep "Deployed to:" | awk '{print $3}'
}

phase_deploy() {
  load_state
  if [ -z "${RSC:-}" ]; then
    RSC=$(deploy_contract "$LASNA_RPC" src/StopLossSentinel.sol:StopLossSentinel $RSC_DEPLOY_LREACT $SEPOLIA_CHAIN $SEPOLIA_CHAIN)
    save_state RSC "$RSC"
  fi
  echo "RSC (Lasna): $RSC"
  cast send "$SYSTEM" "depositTo(address)" "$RSC" --value "${RSC_RESERVE_LREACT}ether" \
    --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" > /dev/null
  echo "RSC reserves funded."

  if [ -z "${VAULT:-}" ]; then
    VAULT=$(deploy_contract "$SEPOLIA_RPC" src/SentinelVault.sol:SentinelVault $VAULT_DEPLOY_ETH "$SEPOLIA_CALLBACK_PROXY" "$RSC")
    save_state VAULT "$VAULT"
  fi
  echo "Vault (Sepolia): $VAULT"
  cast send "$SEPOLIA_CALLBACK_PROXY" "depositTo(address)" "$VAULT" --value "${VAULT_RESERVE_ETH}ether" \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" > /dev/null
  echo "Vault reserves funded."

  cast send "$RSC" "configure(address)" "$VAULT" --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" > /dev/null
  echo "Sentinel configured + subscribed."

  local open_tx
  open_tx=$(cast send "$VAULT" "openPosition(uint256)" $FLOOR --value "${POSITION_ETH}ether" \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
  save_state OPEN_TX "$open_tx"
  echo "Position opened (floor $FLOOR, $POSITION_ETH ETH): $open_tx"
}

phase_drive() {
  load_state
  local ok_tx breach_tx
  ok_tx=$(cast send "$VAULT" "updatePrice(uint256)" $PRICE_OK \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
  save_state PRICE_OK_TX "$ok_tx"
  echo "Benign price $PRICE_OK published: $ok_tx"
  sleep 30
  echo "triggerCount after benign update (expect 0): $(cast call "$RSC" "triggerCount()(uint256)" --rpc-url "$LASNA_RPC")"

  breach_tx=$(cast send "$VAULT" "updatePrice(uint256)" $PRICE_BREACH \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
  save_state BREACH_TX "$breach_tx"
  echo "Breaching price $PRICE_BREACH published: $breach_tx"

  echo "Waiting for the callback to close the position..."
  for i in $(seq 1 60); do
    sleep 10
    open=$(cast call "$VAULT" "positionOpen()(bool)" --rpc-url "$SEPOLIA_RPC" || echo "?")
    trig=$(cast call "$RSC" "triggerCount()(uint256)" --rpc-url "$LASNA_RPC" || echo "?")
    echo "  [$i] positionOpen=$open triggerCount=$trig"
    if [ "$open" = "false" ]; then break; fi
  done

  echo "--- final state ---"
  echo "vault.positionOpen : $(cast call "$VAULT" "positionOpen()(bool)" --rpc-url "$SEPOLIA_RPC")"
  echo "vault.closedAtPrice: $(cast call "$VAULT" "closedAtPrice()(uint256)" --rpc-url "$SEPOLIA_RPC")"
  echo "vault.refundedAmount: $(cast call "$VAULT" "refundedAmount()(uint256)" --rpc-url "$SEPOLIA_RPC")"
  echo "sentinel.triggerCount: $(cast call "$RSC" "triggerCount()(uint256)" --rpc-url "$LASNA_RPC")"
  echo "PositionClosed logs on Sepolia (last tx hash is the callback delivery):"
  cast logs --rpc-url "$SEPOLIA_RPC" --address "$VAULT" "PositionClosed(uint256,uint256)" --from-block -10000 2>/dev/null | grep -E "transactionHash|blockNumber" || true
  echo "StopLossTriggered logs on Lasna (the reactive transaction):"
  cast logs --rpc-url "$LASNA_RPC" --address "$RSC" "StopLossTriggered(uint256,uint256)" --from-block -10000 2>/dev/null | grep -E "transactionHash|blockNumber" || true
}

case "${1:-all}" in
  fund) phase_fund ;;
  deploy) phase_deploy ;;
  drive) phase_drive ;;
  all) phase_fund; phase_deploy; phase_drive ;;
  *) echo "usage: $0 [fund|deploy|drive|all]"; exit 1 ;;
esac
