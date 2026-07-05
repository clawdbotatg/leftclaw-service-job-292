// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAchievementRegistry
 * @notice Minimal interface the {AchievementBadge} contract depends on. The badge is intentionally
 *         coupled only to this interface (never the concrete {AchievementRegistry}) so the registry
 *         implementation can evolve independently as long as the shape below is preserved.
 */
interface IAchievementRegistry {
    /**
     * @notice Canonical definition of a single achievement.
     * @param appId        Application namespace this achievement belongs to (immutable after creation).
     * @param key          Stable machine key unique within an app (immutable after creation).
     * @param name         Human readable display name.
     * @param description  Human readable description.
     * @param tier         Rarity tier: 1 = Common, 2 = Rare, 3 = Legendary.
     * @param imageURI     URI (ipfs://, https://, data:) pointing at the badge artwork.
     * @param maxSupply    Maximum number of badges that can ever be claimed. 0 means uncapped.
     * @param capLocked    When true, `maxSupply` can never be changed again (one-way latch).
     * @param rewardToken  address(0) = no reward, NATIVE_ETH_SENTINEL = native ETH, otherwise an ERC20 address.
     * @param rewardAmount Amount of `rewardToken` paid out on a successful claim.
     * @param prerequisites Achievement ids the claimer must already hold before claiming this one.
     * @param hidden       Frontend display hint only; carries no on-chain enforcement.
     * @param active       When false the achievement cannot be claimed.
     */
    struct AchievementDef {
        string appId;
        string key;
        string name;
        string description;
        uint8 tier;
        string imageURI;
        uint256 maxSupply;
        bool capLocked;
        address rewardToken;
        uint256 rewardAmount;
        uint256[] prerequisites;
        bool hidden;
        bool active;
    }

    /**
     * @notice Returns the full definition for `id`.
     * @dev MUST revert if `id` does not exist so callers can rely on this as an existence check.
     */
    function getAchievement(uint256 id) external view returns (AchievementDef memory);

    /// @notice Returns true if `id` refers to an existing achievement.
    function exists(uint256 id) external view returns (bool);

    /// @notice Returns the number of achievements created so far.
    function totalAchievements() external view returns (uint256);

    /// @notice Returns the prerequisite achievement ids for `id`.
    function getPrerequisites(uint256 id) external view returns (uint256[] memory);
}
