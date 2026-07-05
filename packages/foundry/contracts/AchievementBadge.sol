// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAchievementRegistry} from "./interfaces/IAchievementRegistry.sol";

/**
 * @title AchievementBadge
 * @notice Soulbound (non-transferable) ERC-721 badges minted against definitions held in an
 *         {IAchievementRegistry}. Badges are claimed by presenting an EIP-712 voucher signed by a
 *         trusted backend signer, giving the client a subgraph-free, events-only indexing story:
 *         every state change emits an event.
 *
 * @dev Design highlights:
 *      - Soulbound: badges can be minted and burned but never transferred; all approval surfaces revert.
 *      - Claims are gated by a single-use signed voucher (replay-protected via `eventHash`).
 *      - Rewards (native ETH or ERC20) are paid out of a pool held by this contract AFTER the mint,
 *        and a reward shortfall never reverts the claim — it only emits {RewardShortfall}.
 *      - Fully on-chain, base64-encoded `tokenURI` metadata including a marketplace `attributes` array.
 *      - The contract depends only on {IAchievementRegistry}, not the concrete registry.
 */
contract AchievementBadge is ERC721, Ownable2Step, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Placeholder address used to denote native ETH rewards (Aave/Curve convention).
    address public constant NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev EIP-712 type hash for the claim voucher.
    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(address recipient,uint256 achievementId,bytes32 eventHash,uint256 deadline)");

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Off-chain authorization to claim a specific achievement.
     * @param recipient     Wallet that will receive the badge.
     * @param achievementId Achievement being claimed.
     * @param eventHash     Unique, single-use identifier for the underlying real-world event/action.
     * @param deadline      Unix timestamp after which the voucher is no longer valid.
     */
    struct Voucher {
        address recipient;
        uint256 achievementId;
        bytes32 eventHash;
        uint256 deadline;
    }

    /**
     * @notice Immutable per-token data recorded at mint.
     * @param achievementId Achievement this token represents.
     * @param edition       1-based edition number (equal to the claim count at mint time).
     * @param earnedAt      Block timestamp at which the badge was claimed.
     */
    struct TokenMeta {
        uint256 achievementId;
        uint256 edition;
        uint256 earnedAt;
    }

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error VoucherExpired();
    error EventHashAlreadyConsumed();
    error InvalidVoucherSignature();
    error AchievementNotActive();
    error AlreadyClaimed();
    error PrerequisiteNotMet(uint256 prereqId);
    error SupplyCapExceeded();
    error TransferNotAllowed();
    error SoulboundTokenNoApprovals();
    error ETHTransferFailed();
    error NativeFundingMismatch();
    error ZeroAddress();

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event AchievementClaimed(
        address indexed recipient,
        uint256 indexed achievementId,
        uint256 indexed tokenId,
        uint256 edition,
        bytes32 eventHash
    );
    event RewardPaid(address indexed recipient, uint256 indexed achievementId, address token, uint256 amount);
    event RewardShortfall(address indexed recipient, uint256 indexed achievementId, address token, uint256 amount);
    event PoolFunded(address indexed token, uint256 amount, address indexed from);
    event PoolWithdrawn(address indexed token, uint256 amount, address indexed to);
    event BadgeRevoked(uint256 indexed tokenId, address indexed holder, uint256 indexed achievementId);
    event VoucherSignerUpdated(address indexed previousSigner, address indexed newSigner);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Registry supplying achievement definitions.
    IAchievementRegistry public immutable registry;

    /// @notice Address whose ECDSA signature authorizes claims. Owner-settable post-deploy.
    address public voucherSigner;

    /// @notice Tracks single-use voucher event hashes to prevent replay.
    mapping(bytes32 => bool) public consumedEventHashes;

    /// @notice achievementId => wallet => whether the wallet currently holds this achievement.
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /// @notice achievementId => number of badges ever issued (monotonic; never decremented on revoke).
    mapping(uint256 => uint256) public claimCount;

    /// @dev tokenId => immutable per-token metadata.
    mapping(uint256 => TokenMeta) private _tokenMeta;

    /// @dev achievementId => list of current holders (kept in sync on claim/revoke).
    mapping(uint256 => address[]) private _achievementHolders;

    /// @dev achievementId => holder => 1-based index into `_achievementHolders` (0 = not present).
    mapping(uint256 => mapping(address => uint256)) private _holderIndexInArray;

    /// @dev Next token id to mint. 1-based.
    uint256 private _nextTokenId = 1;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /**
     * @param name_          ERC-721 collection name.
     * @param symbol_        ERC-721 collection symbol.
     * @param registry_      Address of the achievement registry (immutable).
     * @param initialSigner_ Initial voucher signer (typically the deployer as a placeholder).
     * @param initialOwner_  Address that will own this contract.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address registry_,
        address initialSigner_,
        address initialOwner_
    ) ERC721(name_, symbol_) EIP712("AchievementBadge", "1") Ownable(initialOwner_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (initialSigner_ == address(0)) revert ZeroAddress();
        registry = IAchievementRegistry(registry_);
        voucherSigner = initialSigner_;
        emit VoucherSignerUpdated(address(0), initialSigner_);
    }

    // ---------------------------------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Claims an achievement badge by presenting a signed voucher.
     * @dev State-changing effects are all applied BEFORE {_safeMint} to defend against the
     *      ERC-721 `onERC721Received` reentrancy vector (mint calls into contract recipients); the
     *      `nonReentrant` guard is additional defense in depth. Reward payout happens last and can
     *      never revert the claim.
     * @param voucher   The claim voucher.
     * @param signature EIP-712 signature over `voucher` produced by {voucherSigner}.
     */
    function claimAchievement(Voucher calldata voucher, bytes calldata signature) external nonReentrant {
        // 1. Deadline.
        if (block.timestamp > voucher.deadline) revert VoucherExpired();

        // 2. Replay protection.
        if (consumedEventHashes[voucher.eventHash]) revert EventHashAlreadyConsumed();

        // 3. Signature.
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH, voucher.recipient, voucher.achievementId, voucher.eventHash, voucher.deadline
                )
            )
        );
        address signer = ECDSA.recoverCalldata(digest, signature);
        if (signer == address(0) || signer != voucherSigner) revert InvalidVoucherSignature();

        // 4. Achievement must exist (registry reverts otherwise) and be active.
        IAchievementRegistry.AchievementDef memory def = registry.getAchievement(voucher.achievementId);
        if (!def.active) revert AchievementNotActive();

        // 5. Not already held by recipient.
        if (hasClaimed[voucher.achievementId][voucher.recipient]) revert AlreadyClaimed();

        // 6. Prerequisites.
        uint256 prereqLen = def.prerequisites.length;
        for (uint256 i = 0; i < prereqLen; ++i) {
            uint256 prereqId = def.prerequisites[i];
            if (!hasClaimed[prereqId][voucher.recipient]) revert PrerequisiteNotMet(prereqId);
        }

        // 7. Effects (all before the external _safeMint call).
        consumedEventHashes[voucher.eventHash] = true;
        hasClaimed[voucher.achievementId][voucher.recipient] = true;

        uint256 newCount = claimCount[voucher.achievementId] + 1;
        if (def.maxSupply != 0 && newCount > def.maxSupply) revert SupplyCapExceeded();
        claimCount[voucher.achievementId] = newCount;

        uint256 tokenId = _nextTokenId++;
        _tokenMeta[tokenId] =
            TokenMeta({achievementId: voucher.achievementId, edition: newCount, earnedAt: block.timestamp});
        _addHolder(voucher.achievementId, voucher.recipient);

        // 8. Interaction: mint (may call onERC721Received on contract recipients).
        _safeMint(voucher.recipient, tokenId);

        // 9. Emit claim event.
        emit AchievementClaimed(voucher.recipient, voucher.achievementId, tokenId, newCount, voucher.eventHash);

        // 10. Reward payout, last, non-reverting.
        if (def.rewardToken != address(0) && def.rewardAmount > 0) {
            _payReward(def.rewardToken, def.rewardAmount, voucher.recipient, voucher.achievementId);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reward payout
    // ---------------------------------------------------------------------------------------------

    /**
     * @dev Pays `amount` of `token` to `to`. This function MUST NEVER revert: it runs after the mint
     *      has already succeeded and must not undo it. A shortfall (insufficient pool balance or a
     *      failed transfer) is surfaced via {RewardShortfall} rather than a revert. ERC20 transfers
     *      use {SafeERC20-trySafeTransfer} (the non-reverting variant) so even a misbehaving reward
     *      token cannot roll back the claim.
     */
    function _payReward(address token, uint256 amount, address to, uint256 achievementId) internal {
        if (token == NATIVE_ETH_SENTINEL) {
            if (address(this).balance < amount) {
                emit RewardShortfall(to, achievementId, token, amount);
                return;
            }
            (bool ok,) = to.call{value: amount}("");
            if (ok) {
                emit RewardPaid(to, achievementId, token, amount);
            } else {
                emit RewardShortfall(to, achievementId, token, amount);
            }
        } else {
            if (IERC20(token).balanceOf(address(this)) < amount) {
                emit RewardShortfall(to, achievementId, token, amount);
                return;
            }
            if (IERC20(token).trySafeTransfer(to, amount)) {
                emit RewardPaid(to, achievementId, token, amount);
            } else {
                emit RewardShortfall(to, achievementId, token, amount);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Pool management (owner-only)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Funds the reward pool with `amount` of `token`.
     * @dev The reward pool is simply this contract's token/ETH balance — there is no separate ledger.
     *      For native ETH, pass `token == NATIVE_ETH_SENTINEL` and send exactly `amount` as `msg.value`.
     *      For ERC20, the owner must have approved this contract for at least `amount` beforehand.
     */
    function fundPool(address token, uint256 amount) external payable onlyOwner {
        if (token == NATIVE_ETH_SENTINEL) {
            if (msg.value != amount) revert NativeFundingMismatch();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        emit PoolFunded(token, amount, msg.sender);
    }

    /**
     * @notice Withdraws `amount` of `token` from the reward pool to `to`.
     * @dev Unlike the silent reward path, this is an intentional owner action and reverts on failure.
     */
    function withdrawPool(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == NATIVE_ETH_SENTINEL) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit PoolWithdrawn(token, amount, to);
    }

    /// @notice Plain ETH transfers top up the reward pool (the contract's ETH balance IS the pool).
    receive() external payable {}

    // ---------------------------------------------------------------------------------------------
    // Signer management (owner-only)
    // ---------------------------------------------------------------------------------------------

    /// @notice Points the contract at a new voucher signer (e.g. the client's backend key).
    function setVoucherSigner(address newSigner) external onlyOwner {
        emit VoucherSignerUpdated(voucherSigner, newSigner);
        voucherSigner = newSigner;
    }

    // ---------------------------------------------------------------------------------------------
    // Revocation (owner-only)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Revokes (burns) a badge, freeing the wallet+achievement slot for a corrected re-claim.
     * @dev `claimCount` is intentionally NOT decremented: the edition number already issued stays
     *      permanently consumed. This guarantees edition numbers are globally unique and never
     *      collide even if the same wallet re-claims the achievement later with a corrected voucher.
     *      The holder is removed from the holder set via O(1) swap-and-pop.
     */
    function revokeBadge(uint256 tokenId) external onlyOwner {
        address holder = ownerOf(tokenId); // reverts if the token does not exist
        uint256 achievementId = _tokenMeta[tokenId].achievementId;

        hasClaimed[achievementId][holder] = false;
        _removeHolder(achievementId, holder);
        delete _tokenMeta[tokenId];

        _burn(tokenId);

        emit BadgeRevoked(tokenId, holder, achievementId);
    }

    // ---------------------------------------------------------------------------------------------
    // Soulbound enforcement
    // ---------------------------------------------------------------------------------------------

    /**
     * @dev Blocks all transfers while permitting mint (`from == 0`) and burn (`to == 0`). This is the
     *      canonical OZ v5 soulbound pattern: capture the previous owner from `super._update`, and if
     *      the update was a wallet-to-wallet move, revert.
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) revert TransferNotAllowed();
        return from;
    }

    /// @dev Approvals are meaningless on a non-transferable token; all approval surfaces revert.
    function approve(address, uint256) public pure override {
        revert SoulboundTokenNoApprovals();
    }

    /// @dev Approvals are meaningless on a non-transferable token; all approval surfaces revert.
    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTokenNoApprovals();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------------------------------

    /// @notice Fully on-chain, base64-encoded JSON metadata for `tokenId`.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // reverts ERC721NonexistentToken if absent
        TokenMeta memory meta = _tokenMeta[tokenId];
        IAchievementRegistry.AchievementDef memory def = registry.getAchievement(meta.achievementId);

        string memory json = _buildMetadataJSON(def, meta);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _buildMetadataJSON(
        IAchievementRegistry.AchievementDef memory def,
        TokenMeta memory meta
    ) internal pure returns (string memory) {
        return string.concat(
            '{"name":"',
            def.name,
            '","description":"',
            def.description,
            '","image":"',
            def.imageURI,
            '","appId":"',
            def.appId,
            '","tier":"',
            _tierName(def.tier),
            '","edition":"',
            _editionString(meta.edition, def.maxSupply),
            '","hidden":',
            def.hidden ? "true" : "false",
            ',"earnedAt":',
            meta.earnedAt.toString(),
            ',"attributes":',
            _buildAttributesArray(def, meta),
            "}"
        );
    }

    function _buildAttributesArray(
        IAchievementRegistry.AchievementDef memory def,
        TokenMeta memory meta
    ) internal pure returns (string memory) {
        return string.concat(
            '[{"trait_type":"App","value":"',
            def.appId,
            '"},{"trait_type":"Tier","value":"',
            _tierName(def.tier),
            '"},{"trait_type":"Edition","value":',
            meta.edition.toString(),
            '},{"trait_type":"Hidden","value":"',
            def.hidden ? "Yes" : "No",
            '"},{"display_type":"date","trait_type":"Earned At","value":',
            meta.earnedAt.toString(),
            "}]"
        );
    }

    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "Common";
        if (tier == 2) return "Rare";
        if (tier == 3) return "Legendary";
        return "Unknown";
    }

    /// @dev "3 of 10" when capped, plain "3" when uncapped.
    function _editionString(uint256 edition, uint256 maxSupply) internal pure returns (string memory) {
        if (maxSupply == 0) return edition.toString();
        return string.concat(edition.toString(), " of ", maxSupply.toString());
    }

    // ---------------------------------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice Returns every achievement id currently held by `wallet`.
    function achievementsOfWallet(address wallet) external view returns (uint256[] memory) {
        uint256 total = registry.totalAchievements();
        uint256 count;
        for (uint256 id = 1; id <= total; ++id) {
            if (hasClaimed[id][wallet]) ++count;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 j;
        for (uint256 id = 1; id <= total; ++id) {
            if (hasClaimed[id][wallet]) {
                ids[j++] = id;
            }
        }
        return ids;
    }

    /// @notice Returns the current holders of `achievementId`.
    function holdersOfAchievement(uint256 achievementId) external view returns (address[] memory) {
        return _achievementHolders[achievementId];
    }

    /// @notice Returns metadata recorded at mint for `tokenId`. Reverts if the token does not exist.
    function tokenMeta(uint256 tokenId) external view returns (TokenMeta memory) {
        _requireOwned(tokenId);
        return _tokenMeta[tokenId];
    }

    /**
     * @notice Remaining claimable supply for `achievementId`.
     * @dev Returns `type(uint256).max` as a sentinel meaning "uncapped". For capped achievements,
     *      returns 0 once the claim count has reached (or exceeded, if the cap was later shrunk) the cap.
     */
    function remainingSupply(uint256 achievementId) external view returns (uint256) {
        IAchievementRegistry.AchievementDef memory def = registry.getAchievement(achievementId);
        if (def.maxSupply == 0) return type(uint256).max;
        uint256 claimed = claimCount[achievementId];
        return claimed >= def.maxSupply ? 0 : def.maxSupply - claimed;
    }

    /// @notice Number of badges `wallet` holds that belong to `appId`.
    function perAppBadgeCount(address wallet, string calldata appId) external view returns (uint256) {
        bytes32 target = keccak256(bytes(appId));
        uint256 total = registry.totalAchievements();
        uint256 count;
        for (uint256 id = 1; id <= total; ++id) {
            if (hasClaimed[id][wallet]) {
                IAchievementRegistry.AchievementDef memory def = registry.getAchievement(id);
                if (keccak256(bytes(def.appId)) == target) ++count;
            }
        }
        return count;
    }

    // ---------------------------------------------------------------------------------------------
    // Holder-set bookkeeping
    // ---------------------------------------------------------------------------------------------

    function _addHolder(uint256 achievementId, address holder) internal {
        _achievementHolders[achievementId].push(holder);
        // 1-based index so that 0 unambiguously means "not present".
        _holderIndexInArray[achievementId][holder] = _achievementHolders[achievementId].length;
    }

    function _removeHolder(uint256 achievementId, address holder) internal {
        uint256 idx = _holderIndexInArray[achievementId][holder];
        if (idx == 0) return; // not present; nothing to do

        address[] storage holders = _achievementHolders[achievementId];
        uint256 lastIndex = holders.length - 1;
        uint256 removeIndex = idx - 1;

        if (removeIndex != lastIndex) {
            address lastHolder = holders[lastIndex];
            holders[removeIndex] = lastHolder;
            _holderIndexInArray[achievementId][lastHolder] = removeIndex + 1;
        }

        holders.pop();
        delete _holderIndexInArray[achievementId][holder];
    }
}
