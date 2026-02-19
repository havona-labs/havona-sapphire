# havona-sapphire

Sapphire-native smart contracts and tooling for confidential trade finance on [Oasis Sapphire](https://docs.oasis.io/build/sapphire/).

Standard EVM chains expose everything. Sapphire runs contracts inside hardware TEEs — all state is encrypted by the Intel SGX/TDX enclave, validators included. These contracts are built specifically around what that makes possible.

## Contracts

### `ConfidentialOrderBook.sol`

Sealed-bid commodity order book. Traders place buy/sell orders; the matching engine runs inside the TEE. Four Sapphire primitives do the heavy lifting:

**`Sapphire.randomBytes()`** — Hardware VRF from the TEE for tie-breaking when multiple sell orders match a buy at the same price. Unlike `block.prevrandao` or `blockhash`, this cannot be gamed by block producers.

**`Sapphire.padGas()`** — Pads execution to a fixed gas ceiling. Without this, a watcher counting gas on every `placeOrder` call can infer whether a match occurred even though they can't read the state.

**`Sapphire.encrypt()` / `Sapphire.decrypt()`** — Match details (counterparty addresses, execution price, quantity) are encrypted before being emitted as events. The event log is publicly indexed; the payload is not. Counterparties retrieve the decryption key via a signed view call to `getMatchKey()`.

**Signed view calls** — On Sapphire, `msg.sender` is zeroed on unsigned `eth_call`. `getMyOrders()` returns nothing to unauthenticated callers. Wrap your provider with the Sapphire SDK and the signing happens transparently:

```typescript
// ethers.js
import * as sapphire from "@oasisprotocol/sapphire-paratime";
const signer = sapphire.wrap(wallet);
const orders = await book.connect(signer).getMyOrders();
```

```python
# web3.py
from sapphirepy import sapphire
w3 = sapphire.wrap(Web3(Web3.HTTPProvider(rpc)), account)
orders = book.functions.getMyOrders().call({"from": account.address})
```

Also inherits `ERC2771Context` for gasless order placement.

### `TradeAttestation.sol`

On-chain commodity price feed populated by a ROFL oracle (see `/rofl-oracle`). Only the registered ROFL app address can submit prices — the Sapphire runtime enforces this at the TEE level.

Supports batch submission, staleness checks, and historical price storage. Reading prices is open — any contract can call `getPrice(commodityId)`.

### `GaslessTrading.sol`

Deployed `ERC2771Forwarder` instance. Traders sign order data off-chain; a relayer submits and pays ROSE gas. `ConfidentialOrderBook` recovers the real trader via `_msgSender()`.

Sapphire also supports a native on-chain signer variant where the relay key lives inside the TEE — fully trustless, no relayer service required. See the [Sapphire gasless docs](https://docs.oasis.io/build/sapphire/develop/gasless).

## ROFL Oracle

`/rofl-oracle` contains a Python commodity price oracle designed to run as a [ROFL](https://docs.oasis.io/build/rofl/) container.

ROFL runs arbitrary Docker containers inside Intel SGX/TDX enclaves managed through Sapphire. The oracle:
1. Fetches commodity spot prices from external APIs (Yahoo Finance by default, swap in your provider)
2. Signs and submits batch attestations to `TradeAttestation.sol`
3. The Sapphire runtime verifies the ROFL app's on-chain identity before accepting submissions — no oracle committee, no multisig, just TEE attestation

```
                  ┌──────────────────────────────────┐
                  │   ROFL Container (TEE)            │
                  │   oracle.py                       │
                  │   • fetches Refinitiv/Yahoo prices │
                  │   • signs with ROFL enclave key   │
                  └─────────────┬────────────────────┘
                                │ submitBatch()
                                ▼
                  ┌──────────────────────────────────┐
                  │   Sapphire (TEE)                  │
                  │   TradeAttestation.sol            │
                  │   verifies ROFL app identity      │
                  │   stores encrypted price history  │
                  └──────────────────────────────────┘
                                │ getPrice()
                                ▼
                  ConfidentialOrderBook / any contract
```

To deploy your own ROFL oracle:

```bash
# Build and push the container
docker build -t your-registry/havona-trade-oracle:latest ./rofl-oracle
docker push your-registry/havona-trade-oracle:latest

# Register the ROFL app on Sapphire
oasis rofl create --name havona-trade-oracle
oasis rofl secret set ROFL_APP_PRIVATE_KEY <key>
oasis rofl secret set TRADE_ATTESTATION_ADDRESS <addr>
oasis rofl deploy rofl-oracle/rofl.yaml
```

## Build & Test

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies
# sapphire-contracts lives inside oasisprotocol/sapphire-paratime
forge install oasisprotocol/sapphire-paratime
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Run tests on Anvil (blockhash fallback for randomness)
forge test -vvv

# Run tests against Sapphire localnet (real TEE precompiles)
docker run --rm -p 8545:8545 ghcr.io/oasisprotocol/sapphire-dev:latest
forge test --profile sapphire-localnet -vvv
```

On the localnet:
- `Sapphire.randomBytes()` draws from actual TEE entropy
- `Sapphire.padGas()` pads to the target gas amount
- Unsigned `eth_call` zeroes `msg.sender` — `getMyOrders()` returns `[]`
- Signed view call (via SDK) propagates `msg.sender` correctly

## Deploy

```bash
# Testnet (get ROSE from faucet.testnet.oasis.io — select "Sapphire" in the dropdown)
cp .env.example .env

forge create contracts/GaslessTrading.sol:GaslessTrading \
    --rpc-url https://testnet.sapphire.oasis.io \
    --private-key $PRIVATE_KEY \
    --legacy

forge create contracts/ConfidentialOrderBook.sol:ConfidentialOrderBook \
    --constructor-args $FORWARDER_ADDRESS \
    --rpc-url https://testnet.sapphire.oasis.io \
    --private-key $PRIVATE_KEY \
    --legacy

forge create contracts/TradeAttestation.sol:TradeAttestation \
    --constructor-args $DEPLOYER_ADDRESS $ROFL_APP_ADDRESS \
    --rpc-url https://testnet.sapphire.oasis.io \
    --private-key $PRIVATE_KEY \
    --legacy
```

`--legacy` is required — Sapphire does not support EIP-1559 gas pricing.

## Why Sapphire for trade finance

Order books are a confidentiality problem at their core. On any transparent chain, every participant can see every open position. On Sapphire:

- Traders can't see each other's limit prices or queue depth
- The matching engine runs inside the TEE — correct execution is verifiable without revealing the inputs
- Randomness for tie-breaking is manipulation-resistant by construction
- Regulatory disclosure is opt-in per-record rather than global

The same TEE hardware that encrypts contract state powers the ROFL oracle, so price data attestation and order execution share the same trust model.

## References

- [Sapphire developer docs](https://docs.oasis.io/build/sapphire/)
- [ROFL documentation](https://docs.oasis.io/build/rofl/)
- [sapphire-contracts (Solidity)](https://github.com/oasisprotocol/sapphire-paratime/tree/main/contracts)
- [oasis-sapphire-py](https://pypi.org/project/oasis-sapphire-py/)
- [Sapphire localnet Docker](https://hub.docker.com/r/oasisprotocol/sapphire-dev)
- [Testnet explorer](https://explorer.oasis.io/testnet/sapphire)
- [Testnet faucet](https://faucet.testnet.oasis.io/)

## Licence

MIT
