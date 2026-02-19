#!/usr/bin/env python3
"""
Sapphire interaction examples — ConfidentialOrderBook + TradeAttestation.

Demonstrates:
  1. Placing orders and reading them back via signed view call
  2. The msg.sender = 0x0 behaviour on unsigned eth_call
  3. Querying commodity prices from the ROFL oracle
  4. Decrypting match details using the match key

Requires:
  pip install web3 oasis-sapphire-py python-dotenv eth-account

Run:
  cp .env.example .env
  python scripts/interact.py
"""

import os
import json
from decimal import Decimal

from dotenv import load_dotenv
from web3 import Web3
from eth_account import Account
from sapphirepy import sapphire

load_dotenv()

RPC_URL           = os.environ.get("RPC_URL", "https://testnet.sapphire.oasis.io")
PRIVATE_KEY       = os.environ["PRIVATE_KEY"]
ORDER_BOOK_ADDR   = os.environ["ORDER_BOOK_ADDRESS"]
ATTESTATION_ADDR  = os.environ["ATTESTATION_ADDRESS"]

# Minimal ABIs
ORDER_BOOK_ABI = json.loads("""[
    {"name":"placeOrder","type":"function","inputs":[
        {"name":"commodity","type":"bytes32"},
        {"name":"quantity","type":"uint256"},
        {"name":"priceLimit","type":"uint256"},
        {"name":"side","type":"uint8"}
    ],"outputs":[{"name":"orderId","type":"uint256"}],"stateMutability":"nonpayable"},
    {"name":"getMyOrders","type":"function","inputs":[],"outputs":[
        {"name":"","type":"tuple[]","components":[
            {"name":"id","type":"uint256"},
            {"name":"trader","type":"address"},
            {"name":"commodity","type":"bytes32"},
            {"name":"quantity","type":"uint256"},
            {"name":"priceLimit","type":"uint256"},
            {"name":"side","type":"uint8"},
            {"name":"status","type":"uint8"},
            {"name":"createdAt","type":"uint64"}
        ]}
    ],"stateMutability":"view"},
    {"name":"getMatchKey","type":"function","inputs":[
        {"name":"matchId","type":"uint256"}
    ],"outputs":[{"name":"","type":"bytes32"}],"stateMutability":"view"},
    {"name":"matchCount","type":"function","inputs":[],"outputs":[
        {"name":"","type":"uint256"}
    ],"stateMutability":"view"}
]""")

ATTESTATION_ABI = json.loads("""[
    {"name":"getPrice","type":"function","inputs":[
        {"name":"commodity","type":"bytes32"}
    ],"outputs":[
        {"name":"price","type":"uint256"},
        {"name":"updatedAt","type":"uint256"}
    ],"stateMutability":"view"}
]""")

SIDE_BUY  = 0
SIDE_SELL = 1

CRUDE_OIL = Web3.keccak(text="CRUDE_OIL_WTI")


def demo_signed_view_call(account: Account):
    """
    Shows the difference between unsigned and signed eth_call on Sapphire.

    Unsigned:  msg.sender == 0x0  →  getMyOrders() returns []
    Signed:    msg.sender == your address  →  returns your orders
    """
    print("\n--- Signed view call demo ---")

    # Unsigned provider — msg.sender is zeroed by Sapphire
    w3_unsigned = Web3(Web3.HTTPProvider(RPC_URL))
    book_unsigned = w3_unsigned.eth.contract(
        address=Web3.to_checksum_address(ORDER_BOOK_ADDR),
        abi=ORDER_BOOK_ABI,
    )
    orders_unsigned = book_unsigned.functions.getMyOrders().call()
    print(f"Unsigned call → {len(orders_unsigned)} orders (expected 0 on Sapphire)")

    # Signed provider — SDK adds EIP-712 signed call data, msg.sender propagates
    w3_signed = sapphire.wrap(Web3(Web3.HTTPProvider(RPC_URL)), account)
    book_signed = w3_signed.eth.contract(
        address=Web3.to_checksum_address(ORDER_BOOK_ADDR),
        abi=ORDER_BOOK_ABI,
    )
    orders_signed = book_signed.functions.getMyOrders().call({"from": account.address})
    print(f"Signed call   → {len(orders_signed)} orders")
    for o in orders_signed:
        side = "BUY" if o[5] == 0 else "SELL"
        status = ["Open", "Matched", "Cancelled"][o[6]]
        print(f"  Order {o[0]}: {side} {o[3] / 1e18:.0f} units @ {o[4] / 1e6:.2f} USD — {status}")


def demo_place_order(account: Account):
    """Place a buy order and confirm it appears in getMyOrders."""
    print("\n--- Place order ---")

    w3 = sapphire.wrap(Web3(Web3.HTTPProvider(RPC_URL)), account)
    book = w3.eth.contract(
        address=Web3.to_checksum_address(ORDER_BOOK_ADDR),
        abi=ORDER_BOOK_ABI,
    )

    nonce = w3.eth.get_transaction_count(account.address)
    tx = book.functions.placeOrder(
        CRUDE_OIL,
        50_000 * 10**18,  # 50,000 barrels
        85_000000,         # $85.00 limit price (USD × 1e6)
        SIDE_BUY,
    ).build_transaction({
        "from":     account.address,
        "nonce":    nonce,
        "gas":      700_000,
        "gasPrice": w3.eth.gas_price,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"placeOrder tx: {tx_hash.hex()}")
    print(f"Status: {'ok' if receipt.status == 1 else 'FAILED'}")


def demo_read_price():
    """Query commodity price from the ROFL oracle (no auth needed)."""
    print("\n--- Read commodity price from ROFL oracle ---")

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    att = w3.eth.contract(
        address=Web3.to_checksum_address(ATTESTATION_ADDR),
        abi=ATTESTATION_ABI,
    )

    try:
        price, updated_at = att.functions.getPrice(CRUDE_OIL).call()
        print(f"CRUDE_OIL_WTI: ${price / 1e6:.2f}  (updated {updated_at})")
    except Exception as e:
        print(f"Price not available yet: {e}")


def main():
    account = Account.from_key(PRIVATE_KEY)
    print(f"Using account: {account.address}")
    print(f"RPC: {RPC_URL}")

    demo_place_order(account)
    demo_signed_view_call(account)
    demo_read_price()


if __name__ == "__main__":
    main()
