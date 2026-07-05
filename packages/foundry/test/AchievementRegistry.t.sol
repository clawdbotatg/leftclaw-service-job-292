// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AchievementRegistry} from "../contracts/AchievementRegistry.sol";
import {IAchievementRegistry} from "../contracts/interfaces/IAchievementRegistry.sol";

contract AchievementRegistryTest is Test {
    AchievementRegistry internal registry;

    address internal owner;
    address internal stranger = makeAddr("stranger");

    // Re-declared here so `vm.expectEmit` can reference them (events are not inherited for emit).
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

    function setUp() public {
        owner = address(this);
        registry = new AchievementRegistry(owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _def(
        string memory appId,
        string memory key,
        uint8 tier,
        uint256 maxSupply,
        bool capLocked,
        address rewardToken,
        uint256 rewardAmount,
        uint256[] memory prerequisites
    ) internal pure returns (IAchievementRegistry.AchievementDef memory) {
        return IAchievementRegistry.AchievementDef({
            appId: appId,
            key: key,
            name: "Name",
            description: "Desc",
            tier: tier,
            imageURI: "ipfs://img",
            maxSupply: maxSupply,
            capLocked: capLocked,
            rewardToken: rewardToken,
            rewardAmount: rewardAmount,
            prerequisites: prerequisites,
            hidden: false,
            active: true
        });
    }

    function _basicDef() internal pure returns (IAchievementRegistry.AchievementDef memory) {
        return _def("app", "key", 1, 0, false, address(0), 0, new uint256[](0));
    }

    // ---------------------------------------------------------------------------------------------
    // createAchievement
    // ---------------------------------------------------------------------------------------------

    function test_CreateAchievement_ReturnsSequentialIdsStartingAtOne() public {
        assertEq(registry.nextAchievementId(), 1);
        uint256 id1 = registry.createAchievement(_basicDef());
        uint256 id2 = registry.createAchievement(_basicDef());
        uint256 id3 = registry.createAchievement(_basicDef());
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(registry.nextAchievementId(), 4);
        assertEq(registry.totalAchievements(), 3);
    }

    function test_CreateAchievement_EmitsAchievementCreated() public {
        uint256[] memory prereqs = new uint256[](0);
        IAchievementRegistry.AchievementDef memory def =
            _def("myapp", "mykey", 2, 100, false, address(0xBEEF), 42, prereqs);

        vm.expectEmit(true, false, false, true);
        emit AchievementCreated(1, "myapp", "mykey", "Name", 2, 100, false, address(0xBEEF), 42, prereqs);
        registry.createAchievement(def);
    }

    function test_CreateAchievement_StoresDefinitionVerbatim() public {
        uint256 id = registry.createAchievement(_def("app", "key", 3, 7, true, address(0xABCD), 9, new uint256[](0)));
        IAchievementRegistry.AchievementDef memory got = registry.getAchievement(id);
        assertEq(got.appId, "app");
        assertEq(got.key, "key");
        assertEq(got.tier, 3);
        assertEq(got.maxSupply, 7);
        assertTrue(got.capLocked);
        assertEq(got.rewardToken, address(0xABCD));
        assertEq(got.rewardAmount, 9);
        assertTrue(got.active);
    }

    function test_CreateAchievement_RevertsOnInvalidTierZero() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.InvalidTier.selector, uint8(0)));
        registry.createAchievement(_def("app", "key", 0, 0, false, address(0), 0, new uint256[](0)));
    }

    function testFuzz_CreateAchievement_RevertsOnInvalidTier(uint8 tier) public {
        vm.assume(tier < 1 || tier > 3);
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.InvalidTier.selector, tier));
        registry.createAchievement(_def("app", "key", tier, 0, false, address(0), 0, new uint256[](0)));
    }

    function test_CreateAchievement_RevertsWhenPrerequisiteIsZero() public {
        uint256[] memory prereqs = new uint256[](1);
        prereqs[0] = 0;
        vm.expectRevert(AchievementRegistry.InvalidAchievementId.selector);
        registry.createAchievement(_def("app", "key", 1, 0, false, address(0), 0, prereqs));
    }

    function test_CreateAchievement_RevertsWhenPrerequisiteDoesNotExistYet() public {
        // Reference an id >= nextAchievementId (nothing created yet, so id 1 does not exist).
        uint256[] memory prereqs = new uint256[](1);
        prereqs[0] = 5;
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.PrerequisiteDoesNotExist.selector, uint256(5)));
        registry.createAchievement(_def("app", "key", 1, 0, false, address(0), 0, prereqs));
    }

    function test_CreateAchievement_SucceedsWithRealPrerequisites() public {
        uint256 a = registry.createAchievement(_basicDef());
        uint256 b = registry.createAchievement(_basicDef());

        uint256[] memory prereqs = new uint256[](2);
        prereqs[0] = a;
        prereqs[1] = b;
        uint256 c = registry.createAchievement(_def("app", "key", 1, 0, false, address(0), 0, prereqs));

        uint256[] memory got = registry.getPrerequisites(c);
        assertEq(got.length, 2);
        assertEq(got[0], a);
        assertEq(got[1], b);
    }

    // ---------------------------------------------------------------------------------------------
    // Only-owner enforcement
    // ---------------------------------------------------------------------------------------------

    function test_OnlyOwner_CreateAchievement() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.createAchievement(_basicDef());
    }

    function test_OnlyOwner_EditAchievement() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.editAchievement(id, "n", "d", 1, "i", address(0), 0, new uint256[](0), false);
    }

    function test_OnlyOwner_SetMaxSupply() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setMaxSupply(id, 10);
    }

    function test_OnlyOwner_LockSupplyCap() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.lockSupplyCap(id);
    }

    function test_OnlyOwner_DeactivateAchievement() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.deactivateAchievement(id);
    }

    function test_OnlyOwner_ActivateAchievement() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.activateAchievement(id);
    }

    // ---------------------------------------------------------------------------------------------
    // editAchievement
    // ---------------------------------------------------------------------------------------------

    function test_EditAchievement_UpdatesMutableFieldsLeavesIdentityAndSupply() public {
        uint256 id =
            registry.createAchievement(_def("app", "key", 1, 50, false, address(0xAAAA), 5, new uint256[](0)));
        // Lock the cap so we can also assert capLocked is preserved through an edit.
        registry.lockSupplyCap(id);

        uint256[] memory newPrereqs = new uint256[](0);
        registry.editAchievement(id, "NewName", "NewDesc", 3, "ipfs://new", address(0xBBBB), 99, newPrereqs, true);

        IAchievementRegistry.AchievementDef memory got = registry.getAchievement(id);
        // Mutated fields.
        assertEq(got.name, "NewName");
        assertEq(got.description, "NewDesc");
        assertEq(got.tier, 3);
        assertEq(got.imageURI, "ipfs://new");
        assertEq(got.rewardToken, address(0xBBBB));
        assertEq(got.rewardAmount, 99);
        assertTrue(got.hidden);
        // Untouched fields.
        assertEq(got.appId, "app");
        assertEq(got.key, "key");
        assertEq(got.maxSupply, 50);
        assertTrue(got.capLocked);
    }

    function test_EditAchievement_RevertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.AchievementDoesNotExist.selector, uint256(1)));
        registry.editAchievement(1, "n", "d", 1, "i", address(0), 0, new uint256[](0), false);
    }

    // ---------------------------------------------------------------------------------------------
    // setMaxSupply / lockSupplyCap
    // ---------------------------------------------------------------------------------------------

    function test_SetMaxSupply_SucceedsAndEmitsWhenUnlocked() public {
        uint256 id = registry.createAchievement(_basicDef());
        vm.expectEmit(true, false, false, true);
        emit AchievementSupplyUpdated(id, 123);
        registry.setMaxSupply(id, 123);
        assertEq(registry.getAchievement(id).maxSupply, 123);
    }

    function test_SetMaxSupply_RevertsWhenCapLocked() public {
        uint256 id = registry.createAchievement(_basicDef());
        registry.lockSupplyCap(id);
        vm.expectRevert(AchievementRegistry.CapAlreadyLocked.selector);
        registry.setMaxSupply(id, 5);
    }

    function test_LockSupplyCap_IsOneWayLatch() public {
        uint256 id = registry.createAchievement(_basicDef());

        vm.expectEmit(true, false, false, false);
        emit AchievementCapLocked(id);
        registry.lockSupplyCap(id);
        assertTrue(registry.getAchievement(id).capLocked);

        // Second call reverts: there is no path back to false anywhere in the contract.
        vm.expectRevert(AchievementRegistry.CapAlreadyLocked.selector);
        registry.lockSupplyCap(id);

        // And it remains locked.
        assertTrue(registry.getAchievement(id).capLocked);
    }

    // ---------------------------------------------------------------------------------------------
    // activate / deactivate
    // ---------------------------------------------------------------------------------------------

    function test_DeactivateThenActivate_TogglesActiveAndEmits() public {
        uint256 id = registry.createAchievement(_basicDef());
        assertTrue(registry.getAchievement(id).active);

        vm.expectEmit(true, false, false, true);
        emit AchievementActiveStatusChanged(id, false);
        registry.deactivateAchievement(id);
        assertFalse(registry.getAchievement(id).active);

        vm.expectEmit(true, false, false, true);
        emit AchievementActiveStatusChanged(id, true);
        registry.activateAchievement(id);
        assertTrue(registry.getAchievement(id).active);
    }

    function test_Deactivate_RevertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.AchievementDoesNotExist.selector, uint256(1)));
        registry.deactivateAchievement(1);
    }

    function test_Activate_RevertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.AchievementDoesNotExist.selector, uint256(9)));
        registry.activateAchievement(9);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function test_GetAchievement_RevertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.AchievementDoesNotExist.selector, uint256(1)));
        registry.getAchievement(1);
    }

    function test_GetPrerequisites_RevertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(AchievementRegistry.AchievementDoesNotExist.selector, uint256(1)));
        registry.getPrerequisites(1);
    }

    function test_Exists() public {
        assertFalse(registry.exists(0));
        assertFalse(registry.exists(1));
        uint256 id = registry.createAchievement(_basicDef());
        assertTrue(registry.exists(id));
        assertFalse(registry.exists(id + 1));
    }

    function test_TotalAchievements() public {
        assertEq(registry.totalAchievements(), 0);
        registry.createAchievement(_basicDef());
        assertEq(registry.totalAchievements(), 1);
        registry.createAchievement(_basicDef());
        assertEq(registry.totalAchievements(), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: create N achievements and confirm bookkeeping + independent retrieval
    // ---------------------------------------------------------------------------------------------

    function testFuzz_CreateManyAchievements(uint8 rawN, uint256 seed) public {
        uint256 n = bound(uint256(rawN), 1, 50);

        uint8[] memory tiers = new uint8[](n + 1);
        uint256[] memory supplies = new uint256[](n + 1);
        uint256[] memory rewards = new uint256[](n + 1);

        for (uint256 i = 1; i <= n; ++i) {
            uint8 tier = uint8((uint256(keccak256(abi.encode(seed, i, "tier"))) % 3) + 1);
            uint256 maxSupply = uint256(keccak256(abi.encode(seed, i, "supply"))) % 1_000_000;
            uint256 rewardAmount = uint256(keccak256(abi.encode(seed, i, "reward"))) % 1e24;

            tiers[i] = tier;
            supplies[i] = maxSupply;
            rewards[i] = rewardAmount;

            uint256 id = registry.createAchievement(
                _def("app", "key", tier, maxSupply, false, address(0xCAFE), rewardAmount, new uint256[](0))
            );
            assertEq(id, i);
        }

        assertEq(registry.totalAchievements(), n);

        for (uint256 i = 1; i <= n; ++i) {
            IAchievementRegistry.AchievementDef memory got = registry.getAchievement(i);
            assertEq(got.tier, tiers[i]);
            assertEq(got.maxSupply, supplies[i]);
            assertEq(got.rewardAmount, rewards[i]);
            assertTrue(registry.exists(i));
        }
    }
}
