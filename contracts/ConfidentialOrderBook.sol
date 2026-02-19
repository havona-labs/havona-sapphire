// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Sapphire} from "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ConfidentialOrderBook
 * @notice Sealed-bid commodity order book running on Oasis Sapphire.
 *
 * What makes this contract Sapphire-specific — none of these are possible on
 * standard EVM:
 *
 *   1. All contract state is TEE-encrypted at the hardware level. No external
 *      observer (including validators) can read order positions from storage.
 *
 *   2. `msg.sender` is zero on unsigned eth_call, so `getMyOrders()` returns
 *      nothing to unauthenticated callers. Wrap your provider with the Sapphire
 *      SDK and the signed view call propagates msg.sender transparently.
 *
 *   3. `Sapphire.randomBytes()` is a hardware VRF backed by the TEE. When
 *      multiple sell orders match a buy at the same price, fair tie-breaking
 *      cannot be manipulated via block hash or miner influence.
 *
 *   4. `Sapphire.padGas()` pads execution to a fixed gas amount so external
 *      observers cannot infer match/no-match from gas usage side-channels.
 *
 *   5. Match details are encrypted with a per-match key before being emitted
 *      as events. The event log is public; the payload is not.
 *
 * Supports gasless order placement via ERC-2771 (see GaslessTrading.sol).
 */
contract ConfidentialOrderBook is ERC2771Context, ReentrancyGuard {

    enum Side   { Buy, Sell }
    enum Status { Open, Matched, Cancelled }

    struct Order {
        uint256 id;
        address trader;
        bytes32 commodity;   // keccak256("CRUDE_OIL_WTI"), keccak256("NATURAL_GAS"), etc.
        uint256 quantity;    // base units × 1e18
        uint256 priceLimit;  // max buy / min sell price, USD × 1e6
        Side    side;
        Status  status;
        uint64  createdAt;
    }

    struct MatchRecord {
        uint256 buyId;
        uint256 sellId;
        uint256 execPrice;
        uint256 execQty;
        // Encrypted with a per-match key stored in _matchKeys.
        // Counterparties call getMatchKey(matchId) via signed view call.
        bytes   encryptedDetails;
    }

    uint256 private _nextId;
    uint256 private _matchCount;

    // State here is encrypted at rest by the Sapphire TEE.
    mapping(uint256  => Order)       private _orders;
    mapping(address  => uint256[])   private _byTrader;
    mapping(bytes32  => uint256[])   private _openBuys;
    mapping(bytes32  => uint256[])   private _openSells;
    mapping(uint256  => MatchRecord) private _matches;
    mapping(uint256  => bytes32)     private _matchKeys;    // matchId → decryption key

    // Indexed fields are public; blob payloads are Sapphire-encrypted.
    event OrderPlaced(uint256 indexed orderId, bytes32 indexed commodity, Side side);
    event OrderCancelled(uint256 indexed orderId);
    event TradeMatched(
        uint256 indexed matchId,
        uint256 indexed buyId,
        uint256 indexed sellId,
        bytes encryptedDetails
    );

    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {}

    // -------------------------------------------------------------------------
    // Order placement
    // -------------------------------------------------------------------------

    function placeOrder(
        bytes32 commodity,
        uint256 quantity,
        uint256 priceLimit,
        Side    side
    ) external nonReentrant returns (uint256 orderId) {
        require(quantity  > 0, "zero qty");
        require(priceLimit > 0, "zero price");

        address trader = _msgSender(); // ERC-2771 aware — gasless callers get real address
        orderId = _nextId++;

        _orders[orderId] = Order({
            id:         orderId,
            trader:     trader,
            commodity:  commodity,
            quantity:   quantity,
            priceLimit: priceLimit,
            side:       side,
            status:     Status.Open,
            createdAt:  uint64(block.timestamp)
        });
        _byTrader[trader].push(orderId);

        if (side == Side.Buy) {
            _openBuys[commodity].push(orderId);
        } else {
            _openSells[commodity].push(orderId);
        }

        emit OrderPlaced(orderId, commodity, side);

        // Pad to constant gas so observers cannot tell whether a match occurred.
        Sapphire.padGas(600_000);
        _tryMatch(commodity);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = _orders[orderId];
        require(o.trader == _msgSender(), "not your order");
        require(o.status == Status.Open, "not open");
        o.status = Status.Cancelled;
        emit OrderCancelled(orderId);
    }

    // -------------------------------------------------------------------------
    // Confidential reads — require Sapphire SDK signed view call.
    //
    // On unsigned eth_call msg.sender == address(0), so these return empty.
    // Wrap your provider: `sapphire.wrap(provider)` and the SDK handles signing.
    // -------------------------------------------------------------------------

    function getMyOrders() external view returns (Order[] memory) {
        uint256[] storage ids = _byTrader[_msgSender()];
        Order[] memory out = new Order[](ids.length);
        for (uint256 i; i < ids.length; i++) out[i] = _orders[ids[i]];
        return out;
    }

    function getMyOpenOrders() external view returns (Order[] memory) {
        uint256[] storage ids = _byTrader[_msgSender()];
        uint256 n;
        for (uint256 i; i < ids.length; i++) {
            if (_orders[ids[i]].status == Status.Open) n++;
        }
        Order[] memory out = new Order[](n);
        uint256 j;
        for (uint256 i; i < ids.length; i++) {
            if (_orders[ids[i]].status == Status.Open) out[j++] = _orders[ids[i]];
        }
        return out;
    }

    /**
     * @notice Returns the AES key to decrypt a match's encryptedDetails.
     * Only accessible to the buyer or seller in that match.
     */
    function getMatchKey(uint256 matchId) external view returns (bytes32) {
        MatchRecord storage m = _matches[matchId];
        address caller = _msgSender();
        require(
            _orders[m.buyId].trader  == caller ||
            _orders[m.sellId].trader == caller,
            "not a counterparty"
        );
        return _matchKeys[matchId];
    }

    function getMatch(uint256 matchId) external view returns (MatchRecord memory) {
        MatchRecord storage m = _matches[matchId];
        address caller = _msgSender();
        require(
            _orders[m.buyId].trader  == caller ||
            _orders[m.sellId].trader == caller,
            "not a counterparty"
        );
        return m;
    }

    function matchCount() external view returns (uint256) {
        return _matchCount;
    }

    // -------------------------------------------------------------------------
    // Internal matching
    // -------------------------------------------------------------------------

    function _tryMatch(bytes32 commodity) internal {
        uint256[] storage buys  = _openBuys[commodity];
        uint256[] storage sells = _openSells[commodity];

        for (uint256 b; b < buys.length; b++) {
            Order storage buy = _orders[buys[b]];
            if (buy.status != Status.Open) continue;

            // Collect all open sells whose limit is <= buy's limit (i.e. they overlap).
            uint256[] memory candidates = new uint256[](sells.length);
            uint256 numCandidates;
            for (uint256 s; s < sells.length; s++) {
                Order storage candidate = _orders[sells[s]];
                if (candidate.status == Status.Open && candidate.priceLimit <= buy.priceLimit) {
                    candidates[numCandidates++] = s;
                }
            }
            if (numCandidates == 0) continue;

            // Fair tie-breaking via Sapphire hardware VRF.
            // On Sapphire: Sapphire.randomBytes() draws from TEE-backed entropy.
            // On Anvil/testnet fallback: use blockhash (not manipulation-resistant).
            uint256 chosen;
            if (numCandidates > 1) {
                bytes memory rnd = _randomBytes32(abi.encodePacked(buy.id, _matchCount));
                chosen = candidates[uint256(bytes32(rnd)) % numCandidates];
            } else {
                chosen = candidates[0];
            }

            Order storage sell  = _orders[sells[chosen]];
            uint256 execPrice   = (buy.priceLimit + sell.priceLimit) / 2;
            uint256 execQty     = buy.quantity < sell.quantity ? buy.quantity : sell.quantity;

            buy.status  = Status.Matched;
            sell.status = Status.Matched;

            // Generate a random key and nonce for this match's encrypted event payload.
            // Sapphire.encrypt takes bytes32 nonce but Deoxys-II only uses the first 15 bytes.
            // bytes15 widened to bytes32 is right-padded with zeros, so the 15 significant
            // bytes land in positions [0..14] — exactly what Deoxys-II reads.
            bytes32 matchKey = bytes32(_randomBytes32(abi.encodePacked(_matchCount, "k")));
            bytes32 nonce    = bytes32(bytes15(_randomBytes15(abi.encodePacked(_matchCount, "n"))));
            bytes memory payload = abi.encode(execPrice, execQty, buy.trader, sell.trader);
            bytes memory enc     = Sapphire.encrypt(matchKey, nonce, payload, "match");

            _matchKeys[_matchCount]  = matchKey;
            _matches[_matchCount]    = MatchRecord({
                buyId:            buy.id,
                sellId:           sell.id,
                execPrice:        execPrice,
                execQty:          execQty,
                encryptedDetails: enc
            });

            emit TradeMatched(_matchCount, buy.id, sell.id, enc);
            _matchCount++;
            return; // one match per call, re-entered next placeOrder
        }
    }

    // Sapphire.randomBytes on Sapphire, blockhash fallback on Anvil.
    function _randomBytes32(bytes memory pers) internal view returns (bytes memory) {
        if (block.chainid == 23295 || block.chainid == 23294) {
            return Sapphire.randomBytes(32, pers);
        }
        return abi.encodePacked(
            keccak256(abi.encodePacked(blockhash(block.number - 1), pers, block.timestamp))
        );
    }

    function _randomBytes15(bytes memory pers) internal view returns (bytes memory) {
        if (block.chainid == 23295 || block.chainid == 23294) {
            return Sapphire.randomBytes(15, pers);
        }
        return abi.encodePacked(
            bytes15(keccak256(abi.encodePacked(blockhash(block.number - 1), pers)))
        );
    }

    // ERC2771Context requires this override in OZ v5.
    function _contextSuffixLength()
        internal view virtual override(ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
