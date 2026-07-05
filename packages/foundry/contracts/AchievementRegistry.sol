// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAchievementRegistry} from "./interfaces/IAchievementRegistry.sol";

/**
 * @title AchievementRegistry
 * @notice Owner-curated catalogue of achievement definitions. The registry is the single source of
 *         truth for what an achievement is; the {AchievementBadge} contract reads from it to mint
 *         soulbound badges. The registry itself never tracks claims or holders — that lives entirely
 *         in the badge contract.
 * @dev Achievement ids are 1-based and auto-incrementing. Id 0 is reserved as an "invalid / none"
 *      sentinel and is rejected everywhere ids are accepted (e.g. prerequisite arrays).
 */
contract AchievementRegistry is Ownable2Step, IAchievementRegistry {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Thrown when referencing an achievement id that has never been created.
    error AchievementDoesNotExist(uint256 id);
    /// @notice Thrown when `tier` is not one of 1 (Common), 2 (Rare), 3 (Legendary).
    error InvalidTier(uint8 tier);
    /// @notice Thrown when attempting to change a supply cap that has been permanently locked.
    error CapAlreadyLocked();
    /// @notice Thrown when a prerequisite id does not refer to an already-existing achievement.
    error PrerequisiteDoesNotExist(uint256 prereqId);
    /// @notice Thrown when id 0 (the reserved sentinel) is supplied where a real id is required.
    error InvalidAchievementId();
    /// @notice Thrown when a prerequisites array exceeds {MAX_PREREQUISITES}.
    error TooManyPrerequisites(uint256 length);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event AchievementCreated(
        uint256 indexed id,
        string appId,
        string key,
        string name,
        uint8 tier,
        uint256 maxSupply,
        bool capLocked,
        address rewardToken,
        uint256 rewardAmount,
        uint256[] prerequisites
    );

    event AchievementEdited(
        uint256 indexed id,
        string name,
        string description,
        uint8 tier,
        string imageURI,
        address rewardToken,
        uint256 rewardAmount,
        uint256[] prerequisites,
        bool hidden
    );

    event AchievementSupplyUpdated(uint256 indexed id, uint256 newMaxSupply);
    event AchievementCapLocked(uint256 indexed id);
    event AchievementActiveStatusChanged(uint256 indexed id, bool active);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @dev id => definition. Only populated for ids in [1, nextAchievementId).
    mapping(uint256 => AchievementDef) private _achievements;

    /// @notice Next id to be assigned. Starts at 1 so id 0 stays reserved as the invalid sentinel.
    uint256 public nextAchievementId = 1;

    /// @notice Upper bound on prerequisites per achievement — defense-in-depth against an
    ///         accidentally (or maliciously, under a compromised-owner scenario) oversized array
    ///         making claims prohibitively expensive or unclaimable.
    uint256 public constant MAX_PREREQUISITES = 32;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /**
     * @param initialOwner Address that will own the registry (curates the achievement catalogue).
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------------------------------
    // Mutating owner functions
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Creates a new achievement definition and returns its freshly assigned id.
     * @dev Validates that `tier` is 1/2/3 and that every prerequisite already exists (an id in
     *      [1, nextAchievementId)). Forbidding forward-references keeps the prerequisite graph
     *      unambiguous and acyclic-by-construction. The definition is stored verbatim, including
     *      the caller-provided `capLocked` and `active` flags.
     * @param def Full achievement definition to store.
     * @return id The newly assigned achievement id.
     */
    function createAchievement(AchievementDef calldata def) external onlyOwner returns (uint256 id) {
        _validateTier(def.tier);
        _validatePrerequisites(def.prerequisites);

        id = nextAchievementId;
        _achievements[id] = def;
        unchecked {
            nextAchievementId = id + 1;
        }

        _emitCreated(id, def);
    }

    /// @dev Isolated into its own stack frame to avoid stack-too-deep on the multi-field event.
    /// @dev `description`, `hidden` and `active` are omitted from the event (they are always available
    ///      via {getAchievement}); `active`/`hidden` also have their own dedicated change events.
    function _emitCreated(uint256 id, AchievementDef calldata def) private {
        emit AchievementCreated(
            id,
            def.appId,
            def.key,
            def.name,
            def.tier,
            def.maxSupply,
            def.capLocked,
            def.rewardToken,
            def.rewardAmount,
            def.prerequisites
        );
    }

    /**
     * @notice Edits the mutable fields of an existing achievement.
     * @dev `appId`, `key`, `maxSupply` and `capLocked` are intentionally NOT editable here:
     *      identity (appId/key) is immutable, and supply has its own dedicated paths
     *      ({setMaxSupply} / {lockSupplyCap}). Reverts if `id` does not exist.
     */
    function editAchievement(
        uint256 id,
        string calldata name,
        string calldata description,
        uint8 tier,
        string calldata imageURI,
        address rewardToken,
        uint256 rewardAmount,
        uint256[] calldata prerequisites,
        bool hidden
    ) external onlyOwner {
        _requireExists(id);
        _validateTier(tier);
        _validatePrerequisites(prerequisites);

        AchievementDef storage a = _achievements[id];
        a.name = name;
        a.description = description;
        a.tier = tier;
        a.imageURI = imageURI;
        a.rewardToken = rewardToken;
        a.rewardAmount = rewardAmount;
        a.prerequisites = prerequisites;
        a.hidden = hidden;

        emit AchievementEdited(id, name, description, tier, imageURI, rewardToken, rewardAmount, prerequisites, hidden);
    }

    /**
     * @notice Updates the maximum claimable supply for `id`.
     * @dev Only permitted while the cap is not locked. The registry does not know the current claim
     *      count (that lives in the {AchievementBadge} contract), so it cannot prevent the owner from
     *      setting a cap below the number of badges already issued. This is safe: the badge contract
     *      re-validates `maxSupply` against its own claim count at claim time, so a cap set too low
     *      simply blocks future claims — it can never cause over-issuance of existing badges. The
     *      owner is responsible for choosing sensible values.
     * @param id           Achievement id to update.
     * @param newMaxSupply New cap; 0 means uncapped.
     */
    function setMaxSupply(uint256 id, uint256 newMaxSupply) external onlyOwner {
        _requireExists(id);
        AchievementDef storage a = _achievements[id];
        if (a.capLocked) revert CapAlreadyLocked();
        a.maxSupply = newMaxSupply;
        emit AchievementSupplyUpdated(id, newMaxSupply);
    }

    /**
     * @notice Permanently locks the supply cap of `id` so {setMaxSupply} can never change it again.
     * @dev One-way latch: there is no function anywhere that can set `capLocked` back to false.
     *      Idempotent-guarded: reverts if already locked so the event is only emitted on transition.
     */
    function lockSupplyCap(uint256 id) external onlyOwner {
        _requireExists(id);
        AchievementDef storage a = _achievements[id];
        if (a.capLocked) revert CapAlreadyLocked();
        a.capLocked = true;
        emit AchievementCapLocked(id);
    }

    /// @notice Marks `id` inactive so it can no longer be claimed.
    function deactivateAchievement(uint256 id) external onlyOwner {
        _requireExists(id);
        _achievements[id].active = false;
        emit AchievementActiveStatusChanged(id, false);
    }

    /// @notice Marks `id` active so it can be claimed again.
    function activateAchievement(uint256 id) external onlyOwner {
        _requireExists(id);
        _achievements[id].active = true;
        emit AchievementActiveStatusChanged(id, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IAchievementRegistry
    function getAchievement(uint256 id) external view returns (AchievementDef memory) {
        _requireExists(id);
        return _achievements[id];
    }

    /// @inheritdoc IAchievementRegistry
    function exists(uint256 id) public view returns (bool) {
        return id != 0 && id < nextAchievementId;
    }

    /// @inheritdoc IAchievementRegistry
    function totalAchievements() external view returns (uint256) {
        return nextAchievementId - 1;
    }

    /// @inheritdoc IAchievementRegistry
    function getPrerequisites(uint256 id) external view returns (uint256[] memory) {
        _requireExists(id);
        return _achievements[id].prerequisites;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------------------------

    function _requireExists(uint256 id) internal view {
        if (!exists(id)) revert AchievementDoesNotExist(id);
    }

    function _validateTier(uint8 tier) internal pure {
        if (tier < 1 || tier > 3) revert InvalidTier(tier);
    }

    function _validatePrerequisites(uint256[] calldata prerequisites) internal view {
        uint256 len = prerequisites.length;
        if (len > MAX_PREREQUISITES) revert TooManyPrerequisites(len);
        for (uint256 i = 0; i < len; ++i) {
            uint256 prereq = prerequisites[i];
            if (prereq == 0) revert InvalidAchievementId();
            if (!exists(prereq)) revert PrerequisiteDoesNotExist(prereq);
        }
    }
}
