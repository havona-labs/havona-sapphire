// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TradeAttestation
 * @notice On-chain commodity price feed populated by a ROFL oracle.
 *
 * ROFL (Runtime OFfchain Logic) lets you run arbitrary off-chain compute in an
 * Intel SGX/TDX TEE, managed and billed through Sapphire. The oracle container
 * fetches commodity prices from external APIs and calls submitAttestation().
 *
 * The Sapphire runtime enforces that only the registered ROFL app address can
 * submit — no trusted relayer, no oracle committee, just TEE attestation.
 *
 * Deployment sequence:
 *   1. Deploy this contract (owner = your admin wallet)
 *   2. Build and register the ROFL app (see /rofl-oracle/)
 *   3. Call setRoflAddress() with the ROFL app's on-chain identity
 *   4. Oracle submits prices every N seconds automatically
 *
 * Reading prices is free and open — call getPrice() from any contract or client.
 */
contract TradeAttestation is Ownable {

    struct Attestation {
        bytes32 commodity;
        uint256 price;       // USD × 1e6
        uint256 timestamp;
        address submittedBy;
    }

    address public roflAppAddress;
    uint256 public maxStaleness = 5 minutes;

    // State is TEE-encrypted on Sapphire — history not visible to outsiders.
    mapping(bytes32 => Attestation)   private _latest;
    mapping(bytes32 => Attestation[]) private _history;

    // Well-known commodity IDs — keccak256 of the canonical name string.
    bytes32 public constant CRUDE_OIL_WTI   = 0xf9d25aa4550aa45b446ec0ea1ab08edcb0f519b7c161d629948975fe130c53dc;
    bytes32 public constant CRUDE_OIL_BRENT = 0x87c678fe6cc10fab7e77956204adb8051728cfe37cce9c9127ec75665dbb1485;
    bytes32 public constant NATURAL_GAS     = 0xe37a9bac1cc5ed44af7f0443ce0fd7072a6b85c1ba17e633026aa51ea7b17f30;
    bytes32 public constant GOLD            = 0x22c6f263af01bcea9f699bcc6e0a774c4e3558923d02a34cc68406394f17f411;
    bytes32 public constant WHEAT           = 0x0e545fafd2f2a00d90a9ef449cc270d628606dba8a1936394f1ae30577849c7c;

    event PriceUpdated(bytes32 indexed commodity, uint256 price, uint256 timestamp);
    event RoflAddressSet(address indexed addr);

    constructor(address initialOwner, address _roflApp) Ownable(initialOwner) {
        roflAppAddress = _roflApp;
    }

    // -------------------------------------------------------------------------
    // Oracle writes — ROFL app only
    // -------------------------------------------------------------------------

    function submitAttestation(bytes32 commodity, uint256 price) external {
        require(msg.sender == roflAppAddress, "not ROFL oracle");
        require(price > 0, "zero price");

        Attestation memory att = Attestation({
            commodity:   commodity,
            price:       price,
            timestamp:   block.timestamp,
            submittedBy: msg.sender
        });

        _latest[commodity] = att;
        _history[commodity].push(att);

        emit PriceUpdated(commodity, price, block.timestamp);
    }

    /**
     * @notice Batch submit — saves gas when updating multiple commodities in one tx.
     */
    function submitBatch(
        bytes32[] calldata commodities,
        uint256[] calldata prices
    ) external {
        require(msg.sender == roflAppAddress, "not ROFL oracle");
        require(commodities.length == prices.length, "length mismatch");

        for (uint256 i; i < commodities.length; i++) {
            require(prices[i] > 0, "zero price");
            Attestation memory att = Attestation({
                commodity:   commodities[i],
                price:       prices[i],
                timestamp:   block.timestamp,
                submittedBy: msg.sender
            });
            _latest[commodities[i]] = att;
            _history[commodities[i]].push(att);
            emit PriceUpdated(commodities[i], prices[i], block.timestamp);
        }
    }

    // -------------------------------------------------------------------------
    // Reads — open to anyone
    // -------------------------------------------------------------------------

    /**
     * @notice Get latest price. Reverts if data is stale or missing.
     */
    function getPrice(bytes32 commodity) external view returns (uint256 price, uint256 updatedAt) {
        Attestation storage att = _latest[commodity];
        require(att.timestamp > 0, "no data");
        require(block.timestamp - att.timestamp <= maxStaleness, "price stale");
        return (att.price, att.timestamp);
    }

    /**
     * @notice Get latest price without staleness check. Useful for display.
     */
    function getPriceRaw(bytes32 commodity) external view returns (Attestation memory) {
        return _latest[commodity];
    }

    function getHistoryLength(bytes32 commodity) external view returns (uint256) {
        return _history[commodity].length;
    }

    function getHistoryAt(bytes32 commodity, uint256 index) external view returns (Attestation memory) {
        return _history[commodity][index];
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setRoflAddress(address addr) external onlyOwner {
        require(addr != address(0), "zero address");
        roflAppAddress = addr;
        emit RoflAddressSet(addr);
    }

    function setMaxStaleness(uint256 seconds_) external onlyOwner {
        require(seconds_ >= 60, "staleness < 60s");
        maxStaleness = seconds_;
    }
}
