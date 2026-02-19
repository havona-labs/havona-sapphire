#!/usr/bin/env python3
"""
ROFL Commodity Price Oracle — Havona

Runs inside an Intel SGX/TDX TEE as a ROFL container on Oasis Sapphire.
Fetches commodity spot prices from external APIs and submits signed
attestations to TradeAttestation.sol.

When running as a proper ROFL app:
  - The ROFL runtime injects the signing key via ROFL_APP_PRIVATE_KEY
  - Sapphire verifies the ROFL app's on-chain identity before accepting submissions
  - No external trust assumptions — TEE attestation is the proof

Running locally (development / testing):
  pip install web3 oasis-sapphire-py requests python-dotenv
  cp .env.example .env  # fill in your keys
  python oracle.py
"""

import os
import sys
import time
import logging
from decimal import Decimal

import requests
from dotenv import load_dotenv
from web3 import Web3
from eth_account import Account

try:
    from sapphirepy import sapphire
    SAPPHIRE_AVAILABLE = True
except ImportError:
    SAPPHIRE_AVAILABLE = False
    logging.warning("oasis-sapphire-py not installed — running without TEE view call auth")

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
)
log = logging.getLogger(__name__)

# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------

RPC_URL             = os.environ.get("RPC_URL", "https://testnet.sapphire.oasis.io")
PRIVATE_KEY         = os.environ["ROFL_APP_PRIVATE_KEY"]          # injected by ROFL runtime
CONTRACT_ADDRESS    = os.environ["TRADE_ATTESTATION_ADDRESS"]
POLL_INTERVAL       = int(os.environ.get("POLL_INTERVAL_SECONDS", "60"))

# Commodity sources — extend freely. price returned in USD.
COMMODITY_SOURCES = {
    # commodity_id: fetch_fn
    "CRUDE_OIL_WTI":    lambda: _fetch_commodity("CL=F"),
    "CRUDE_OIL_BRENT":  lambda: _fetch_commodity("BZ=F"),
    "NATURAL_GAS":      lambda: _fetch_commodity("NG=F"),
    "XAU_USD":          lambda: _fetch_commodity("GC=F"),
    "WHEAT_USD":        lambda: _fetch_commodity("ZW=F"),
}

# Matches keccak256() of the string in TradeAttestation.sol
COMMODITY_IDS = {
    name: Web3.keccak(text=name) for name in COMMODITY_SOURCES
}

# ABI — only the functions we call
ABI = [
    {
        "name": "submitAttestation",
        "type": "function",
        "inputs": [
            {"name": "commodity", "type": "bytes32"},
            {"name": "price",     "type": "uint256"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
    {
        "name": "submitBatch",
        "type": "function",
        "inputs": [
            {"name": "commodities", "type": "bytes32[]"},
            {"name": "prices",      "type": "uint256[]"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
]

# -------------------------------------------------------------------------
# Price fetching — replace with your preferred data provider
# -------------------------------------------------------------------------

def _fetch_commodity(ticker: str) -> Decimal | None:
    """
    Fetch spot price from Yahoo Finance (no API key needed, rate-limited).
    In production, use a paid data provider: Refinitiv, Bloomberg, ICE, etc.
    """
    try:
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}"
        resp = requests.get(url, timeout=10, headers={"User-Agent": "HavonaOracle/1.0"})
        resp.raise_for_status()
        data = resp.json()
        price = data["chart"]["result"][0]["meta"]["regularMarketPrice"]
        return Decimal(str(price))
    except Exception as exc:
        log.warning("Failed to fetch %s: %s", ticker, exc)
        return None


def fetch_all_prices() -> dict[str, int]:
    """Returns commodity_id → price in USD × 1e6 (uint256 format)."""
    prices = {}
    for name, fetch_fn in COMMODITY_SOURCES.items():
        price = fetch_fn()
        if price is not None and price > 0:
            # Convert to uint256: USD × 1e6 (matches TradeAttestation.sol)
            prices[name] = int(price * 1_000_000)
            log.info("  %-20s  $%.4f  (raw: %d)", name, price, prices[name])
    return prices


# -------------------------------------------------------------------------
# Chain submission
# -------------------------------------------------------------------------

def submit_prices(w3: Web3, contract, account: Account, prices: dict[str, int]):
    if not prices:
        log.warning("No prices fetched, skipping submission")
        return

    commodities = [COMMODITY_IDS[name] for name in prices]
    price_list  = [prices[name] for name in prices]

    try:
        nonce = w3.eth.get_transaction_count(account.address)
        tx = contract.functions.submitBatch(commodities, price_list).build_transaction({
            "from":     account.address,
            "nonce":    nonce,
            "gas":      500_000,
            "gasPrice": w3.eth.gas_price,
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

        if receipt.status == 1:
            log.info("Batch submitted: %s (%d commodities)", tx_hash.hex(), len(prices))
        else:
            log.error("Transaction failed: %s", tx_hash.hex())

    except Exception as exc:
        log.error("Submission error: %s", exc)
        raise


# -------------------------------------------------------------------------
# Main loop
# -------------------------------------------------------------------------

def main():
    log.info("Havona ROFL Oracle starting")
    log.info("  RPC:      %s", RPC_URL)
    log.info("  Contract: %s", CONTRACT_ADDRESS)
    log.info("  Interval: %ds", POLL_INTERVAL)

    account = Account.from_key(PRIVATE_KEY)
    log.info("  Address:  %s", account.address)

    w3 = Web3(Web3.HTTPProvider(RPC_URL))

    # Wrap with Sapphire SDK for encrypted transactions + authenticated view calls.
    if SAPPHIRE_AVAILABLE:
        w3 = sapphire.wrap(w3, account)
        log.info("  Sapphire SDK: active (EIP-712 signed calls)")
    else:
        log.warning("  Sapphire SDK: inactive (pip install oasis-sapphire-py)")

    if not w3.is_connected():
        log.error("Cannot connect to %s", RPC_URL)
        sys.exit(1)

    chain_id = w3.eth.chain_id
    log.info("  Chain ID: %d", chain_id)

    contract = w3.eth.contract(
        address=Web3.to_checksum_address(CONTRACT_ADDRESS),
        abi=ABI,
    )

    while True:
        log.info("Fetching commodity prices…")
        prices = fetch_all_prices()
        if prices:
            submit_prices(w3, contract, account, prices)
        else:
            log.warning("All fetches failed, will retry in %ds", POLL_INTERVAL)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
