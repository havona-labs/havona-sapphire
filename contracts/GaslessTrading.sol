// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/**
 * @title GaslessTrading
 * @notice ERC-2771 forwarder that lets traders place orders without holding ROSE.
 *
 * How it works:
 *   1. Trader signs an order placement calldata off-chain (no gas, free).
 *   2. A relayer submits the signed request to this forwarder.
 *   3. The forwarder verifies the signature and calls ConfidentialOrderBook,
 *      appending the original trader's address to the calldata.
 *   4. ConfidentialOrderBook inherits ERC2771Context and recovers the real
 *      trader via _msgSender() — the relayer is invisible to the order book.
 *
 * The relayer can be anyone: your backend, a third-party GSN provider, or
 * another trader who sponsors gas (e.g. a market maker subsidising takers).
 *
 * Sapphire-native alternative:
 *   Sapphire supports a fully on-chain signer variant where the relay signing
 *   key lives inside the TEE — no relayer service needed, fully decentralised.
 *   See: https://docs.oasis.io/build/sapphire/develop/gasless
 *
 * This contract is just a deployed instance of OpenZeppelin's ERC2771Forwarder.
 * ConfidentialOrderBook is deployed with this contract's address as the trusted
 * forwarder, so the pattern is: deploy forwarder → deploy order book with
 * forwarder address → relayers submit to forwarder.
 */
contract GaslessTrading is ERC2771Forwarder {
    constructor() ERC2771Forwarder("HavonaGaslessTrading") {}
}
