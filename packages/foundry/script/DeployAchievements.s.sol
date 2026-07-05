// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import {AchievementRegistry} from "../contracts/AchievementRegistry.sol";
import {AchievementBadge} from "../contracts/AchievementBadge.sol";

/**
 * @notice Deploy script for the AchievementRegistry + AchievementBadge system.
 * @dev Inherits ScaffoldETHDeploy for the `deployer`/broadcast plumbing and address export.
 *
 * Example:
 *   yarn deploy --file DeployAchievements.s.sol             # local anvil chain
 *   yarn deploy --file DeployAchievements.s.sol --network base
 */
contract DeployAchievements is ScaffoldETHDeploy {
    /**
     * @dev Permanent owner of BOTH contracts: the client wallet from the leftclaw job
     *      (`job.client`). This is public on-chain job data, not a secret, so a Solidity constant is
     *      the appropriate place for it.
     */
    address constant CLIENT_WALLET = 0xf2c44aF68aE2a983d1331b2D3aEF3c516Ae4a0Fc;

    // ERC-721 collection identity for the badge contract.
    string constant BADGE_NAME = "Achievement Badge";
    string constant BADGE_SYMBOL = "ACHV";

    /**
     * @dev Ownership decision: we deploy BOTH contracts directly with CLIENT_WALLET as `initialOwner`
     *      rather than using a deployer-first-then-transfer pattern. There is no post-deploy step that
     *      requires deployer privileges — the only cross-contract link is the badge knowing the
     *      registry's address, which is a constructor argument (not a post-deploy setter). Deploying
     *      straight to the final owner avoids an unnecessary two-step Ownable2Step handoff.
     *
     *      The one thing the new owner must still do post-deploy is call `setVoucherSigner(...)` with
     *      their real backend signing key. Until then the voucher signer is set to the deployer as a
     *      placeholder (so no third party can forge valid vouchers in the meantime).
     */
    function run() external ScaffoldEthDeployerRunner {
        AchievementRegistry registry = new AchievementRegistry(CLIENT_WALLET);

        AchievementBadge badge = new AchievementBadge(
            BADGE_NAME,
            BADGE_SYMBOL,
            address(registry),
            deployer, // placeholder voucher signer; owner replaces via setVoucherSigner post-deploy
            CLIENT_WALLET
        );

        deployments.push(Deployment({name: "AchievementRegistry", addr: address(registry)}));
        deployments.push(Deployment({name: "AchievementBadge", addr: address(badge)}));

        console.log("AchievementRegistry deployed at:", address(registry));
        console.log("AchievementBadge    deployed at:", address(badge));
        console.log("Owner of both contracts:", CLIENT_WALLET);
        console.log("Placeholder voucher signer (deployer):", deployer);
        console.log("REMINDER: new owner must call setVoucherSigner(<backend key>) before going live.");
    }
}
