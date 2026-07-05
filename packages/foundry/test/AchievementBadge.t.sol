// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AchievementRegistry} from "../contracts/AchievementRegistry.sol";
import {AchievementBadge} from "../contracts/AchievementBadge.sol";
import {IAchievementRegistry} from "../contracts/interfaces/IAchievementRegistry.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AchievementBadgeTest is Test {
    AchievementRegistry internal registry;
    AchievementBadge internal badge;
    MockERC20 internal token;

    address internal owner; // == address(this)
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant WRONG_PK = 0xB0B;
    address internal signer;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Shared achievement ids created in setUp.
    uint256 internal idBasic; // uncapped, no reward, no prereq, appId "app1"
    uint256 internal idCapped; // maxSupply = 3, no reward
    uint256 internal idErc20; // ERC20 reward, uncapped, amount = REWARD_ERC20
    uint256 internal idNative; // native ETH reward, uncapped, amount = REWARD_NATIVE
    uint256 internal idPrereq; // requires idBasic, uncapped, appId "app2"

    uint256 internal constant REWARD_ERC20 = 100e18;
    uint256 internal constant REWARD_NATIVE = 1 ether;

    uint256 internal _mintedSoFar; // running count of successful mints via _claim (== last tokenId)
    uint256 internal _hashNonce; // for generating unique eventHashes

    // Re-declared for expectEmit.
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

    receive() external payable {}

    function setUp() public {
        owner = address(this);
        signer = vm.addr(SIGNER_PK);

        // Move away from timestamp 0/1 so we can build already-expired deadlines without underflow.
        vm.warp(1_000_000);

        registry = new AchievementRegistry(owner);
        badge = new AchievementBadge("Achievement Badge", "ACHV", address(registry), signer, owner);

        token = new MockERC20();
        token.mint(owner, 1_000_000e18);

        idBasic = registry.createAchievement(_def("app1", "basic", 1, 0, address(0), 0, new uint256[](0)));
        idCapped = registry.createAchievement(_def("app1", "capped", 2, 3, address(0), 0, new uint256[](0)));
        idErc20 = registry.createAchievement(_def("app1", "erc20", 1, 0, address(token), REWARD_ERC20, new uint256[](0)));
        idNative = registry.createAchievement(_def("app1", "native", 1, 0, NATIVE, REWARD_NATIVE, new uint256[](0)));

        uint256[] memory pre = new uint256[](1);
        pre[0] = idBasic;
        idPrereq = registry.createAchievement(_def("app2", "prereq", 3, 0, address(0), 0, pre));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _def(
        string memory appId,
        string memory key,
        uint8 tier,
        uint256 maxSupply,
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
            capLocked: false,
            rewardToken: rewardToken,
            rewardAmount: rewardAmount,
            prerequisites: prerequisites,
            hidden: false,
            active: true
        });
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AchievementBadge")),
                keccak256(bytes("1")),
                block.chainid,
                address(badge)
            )
        );
    }

    function _digest(AchievementBadge.Voucher memory v) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(badge.VOUCHER_TYPEHASH(), v.recipient, v.achievementId, v.eventHash, v.deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(uint256 pk, AchievementBadge.Voucher memory v) internal view returns (bytes memory) {
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(pk, _digest(v));
        return abi.encodePacked(r, s, vSig);
    }

    function _nextHash() internal returns (bytes32) {
        return keccak256(abi.encode("eventHash", ++_hashNonce));
    }

    function _voucher(uint256 achievementId, address recipient, bytes32 eventHash)
        internal
        view
        returns (AchievementBadge.Voucher memory)
    {
        return AchievementBadge.Voucher({
            recipient: recipient,
            achievementId: achievementId,
            eventHash: eventHash,
            deadline: block.timestamp + 1 days
        });
    }

    /// @dev Claims via a valid signer voucher and returns the freshly minted tokenId.
    function _claim(uint256 achievementId, address recipient) internal returns (uint256 tokenId, bytes32 eventHash) {
        eventHash = _nextHash();
        AchievementBadge.Voucher memory v = _voucher(achievementId, recipient, eventHash);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));
        tokenId = ++_mintedSoFar;
    }

    // ---------------------------------------------------------------------------------------------
    // Claiming happy path
    // ---------------------------------------------------------------------------------------------

    function test_ClaimAchievement_HappyPath() public {
        address alice = makeAddr("alice");
        bytes32 eh = _nextHash();
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, eh);

        vm.expectEmit(true, true, true, true);
        emit AchievementClaimed(alice, idBasic, 1, 1, eh);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));

        assertEq(badge.ownerOf(1), alice);
        assertTrue(badge.hasClaimed(idBasic, alice));
        assertEq(badge.claimCount(idBasic), 1);
        assertTrue(badge.consumedEventHashes(eh));

        // token appears in the wallet + holder views
        uint256[] memory owned = badge.achievementsOfWallet(alice);
        assertEq(owned.length, 1);
        assertEq(owned[0], idBasic);

        address[] memory holders = badge.holdersOfAchievement(idBasic);
        assertEq(holders.length, 1);
        assertEq(holders[0], alice);
    }

    function test_ClaimAchievement_AnyoneCanSubmitValidVoucher() public {
        address alice = makeAddr("alice");
        bytes32 eh = _nextHash();
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, eh);
        bytes memory sig = _sign(SIGNER_PK, v);

        // A different address submits; the badge must mint to the voucher's recipient, not msg.sender.
        vm.prank(stranger);
        badge.claimAchievement(v, sig);

        assertEq(badge.ownerOf(1), alice);
        assertFalse(badge.hasClaimed(idBasic, stranger));
        assertTrue(badge.hasClaimed(idBasic, alice));
    }

    // ---------------------------------------------------------------------------------------------
    // Voucher validation
    // ---------------------------------------------------------------------------------------------

    function test_ClaimAchievement_RevertsWhenExpired() public {
        address alice = makeAddr("alice");
        AchievementBadge.Voucher memory v = AchievementBadge.Voucher({
            recipient: alice,
            achievementId: idBasic,
            eventHash: _nextHash(),
            deadline: block.timestamp - 1
        });
        bytes memory sig = _sign(SIGNER_PK, v);
        vm.expectRevert(AchievementBadge.VoucherExpired.selector);
        badge.claimAchievement(v, sig);
    }

    function test_ClaimAchievement_RevertsOnEventHashReplay() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        bytes32 eh = _nextHash();

        AchievementBadge.Voucher memory v1 = _voucher(idBasic, alice, eh);
        badge.claimAchievement(v1, _sign(SIGNER_PK, v1));

        // Reuse the SAME eventHash for a different achievement AND recipient: must still revert,
        // proving eventHash consumption is global rather than scoped per (achievement, wallet).
        AchievementBadge.Voucher memory v2 = _voucher(idCapped, bob, eh);
        bytes memory sig2 = _sign(SIGNER_PK, v2);
        vm.expectRevert(AchievementBadge.EventHashAlreadyConsumed.selector);
        badge.claimAchievement(v2, sig2);
    }

    function test_ClaimAchievement_RevertsOnBadSignature() public {
        address alice = makeAddr("alice");
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, _nextHash());
        // Signed by a key that is not the voucherSigner.
        bytes memory sig = _sign(WRONG_PK, v);
        vm.expectRevert(AchievementBadge.InvalidVoucherSignature.selector);
        badge.claimAchievement(v, sig);
    }

    function test_ClaimAchievement_RevertsOnTamperedVoucher() public {
        address alice = makeAddr("alice");
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, _nextHash());
        bytes memory sig = _sign(SIGNER_PK, v); // sign for idBasic

        // Tamper: change achievementId after signing. Digest no longer matches -> recovered signer differs.
        v.achievementId = idCapped;
        vm.expectRevert(AchievementBadge.InvalidVoucherSignature.selector);
        badge.claimAchievement(v, sig);
    }

    function test_ClaimAchievement_RevertsWhenAlreadyClaimed() public {
        address alice = makeAddr("alice");
        _claim(idBasic, alice);

        // Fresh, distinct eventHash so replay protection is not what trips: AlreadyClaimed must.
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, _nextHash());
        bytes memory sig = _sign(SIGNER_PK, v);
        vm.expectRevert(AchievementBadge.AlreadyClaimed.selector);
        badge.claimAchievement(v, sig);
    }

    function test_ClaimAchievement_RevertsWhenNotActive() public {
        address alice = makeAddr("alice");
        registry.deactivateAchievement(idBasic);

        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, _nextHash());
        bytes memory sig = _sign(SIGNER_PK, v);
        vm.expectRevert(AchievementBadge.AchievementNotActive.selector);
        badge.claimAchievement(v, sig);

        // Reactivate -> succeeds.
        registry.activateAchievement(idBasic);
        _claim(idBasic, alice);
        assertTrue(badge.hasClaimed(idBasic, alice));
    }

    // ---------------------------------------------------------------------------------------------
    // Supply cap
    // ---------------------------------------------------------------------------------------------

    function test_RemainingSupply_UncappedReturnsMax() public view {
        assertEq(badge.remainingSupply(idBasic), type(uint256).max);
    }

    function testFuzz_SupplyCap_Enforced(uint8 rawN) public {
        uint256 n = bound(uint256(rawN), 1, 5);
        uint256 id = registry.createAchievement(_def("app1", "fuzzcap", 1, n, address(0), 0, new uint256[](0)));

        for (uint256 i = 0; i < n; ++i) {
            address w = makeAddr(string.concat("capWallet", vm.toString(i)));
            AchievementBadge.Voucher memory v = _voucher(id, w, _nextHash());
            badge.claimAchievement(v, _sign(SIGNER_PK, v));
            assertEq(badge.remainingSupply(id), n - i - 1);
        }
        assertEq(badge.remainingSupply(id), 0);
        assertEq(badge.claimCount(id), n);

        // The (N+1)th claim reverts.
        address extra = makeAddr("capExtra");
        AchievementBadge.Voucher memory vx = _voucher(id, extra, _nextHash());
        bytes memory sigx = _sign(SIGNER_PK, vx);
        vm.expectRevert(AchievementBadge.SupplyCapExceeded.selector);
        badge.claimAchievement(vx, sigx);
    }

    // ---------------------------------------------------------------------------------------------
    // Prerequisites
    // ---------------------------------------------------------------------------------------------

    function test_Claim_RevertsWhenPrerequisiteNotMet() public {
        address alice = makeAddr("alice");
        AchievementBadge.Voucher memory v = _voucher(idPrereq, alice, _nextHash());
        bytes memory sig = _sign(SIGNER_PK, v);
        vm.expectRevert(abi.encodeWithSelector(AchievementBadge.PrerequisiteNotMet.selector, idBasic));
        badge.claimAchievement(v, sig);
    }

    function test_Claim_SucceedsOncePrerequisiteHeld() public {
        address alice = makeAddr("alice");
        _claim(idBasic, alice);
        _claim(idPrereq, alice);
        assertTrue(badge.hasClaimed(idPrereq, alice));
    }

    function test_Claim_ChainOfPrerequisites_PartiallyMet() public {
        address alice = makeAddr("alice");
        uint256 idOther = registry.createAchievement(_def("app1", "other", 1, 0, address(0), 0, new uint256[](0)));

        uint256[] memory pre = new uint256[](2);
        pre[0] = idBasic;
        pre[1] = idOther;
        uint256 idChain = registry.createAchievement(_def("app1", "chain", 2, 0, address(0), 0, pre));

        // Meet only the first prerequisite; the second (idOther) is missing.
        _claim(idBasic, alice);
        AchievementBadge.Voucher memory v = _voucher(idChain, alice, _nextHash());
        bytes memory sig = _sign(SIGNER_PK, v);
        vm.expectRevert(abi.encodeWithSelector(AchievementBadge.PrerequisiteNotMet.selector, idOther));
        badge.claimAchievement(v, sig);

        // Meet the second too -> succeeds.
        _claim(idOther, alice);
        _claim(idChain, alice);
        assertTrue(badge.hasClaimed(idChain, alice));
    }

    // ---------------------------------------------------------------------------------------------
    // Reward payout - ERC20
    // ---------------------------------------------------------------------------------------------

    function test_Reward_ERC20_PaidWhenPoolFunded() public {
        address alice = makeAddr("alice");
        token.approve(address(badge), REWARD_ERC20);
        badge.fundPool(address(token), REWARD_ERC20);

        uint256 before = token.balanceOf(alice);
        AchievementBadge.Voucher memory v = _voucher(idErc20, alice, _nextHash());
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, idErc20, address(token), REWARD_ERC20);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));

        assertEq(token.balanceOf(alice), before + REWARD_ERC20);
    }

    function test_Reward_ERC20_ShortfallDoesNotRevert() public {
        address alice = makeAddr("alice");
        // Pool NOT funded (or funded insufficiently): fund only half.
        token.approve(address(badge), REWARD_ERC20 / 2);
        badge.fundPool(address(token), REWARD_ERC20 / 2);

        uint256 before = token.balanceOf(alice);
        AchievementBadge.Voucher memory v = _voucher(idErc20, alice, _nextHash());
        vm.expectEmit(true, true, false, true);
        emit RewardShortfall(alice, idErc20, address(token), REWARD_ERC20);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));

        // Claim succeeded: badge minted, hasClaimed set, balance unchanged.
        assertEq(badge.ownerOf(1), alice);
        assertTrue(badge.hasClaimed(idErc20, alice));
        assertEq(token.balanceOf(alice), before);
    }

    // ---------------------------------------------------------------------------------------------
    // Reward payout - native ETH
    // ---------------------------------------------------------------------------------------------

    function test_Reward_Native_PaidWhenFundedViaFundPool() public {
        address alice = makeAddr("alice");
        vm.deal(owner, REWARD_NATIVE);
        badge.fundPool{value: REWARD_NATIVE}(NATIVE, REWARD_NATIVE);

        uint256 before = alice.balance;
        AchievementBadge.Voucher memory v = _voucher(idNative, alice, _nextHash());
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(alice, idNative, NATIVE, REWARD_NATIVE);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));

        assertEq(alice.balance, before + REWARD_NATIVE);
    }

    function test_Reward_Native_PaidWhenFundedViaReceive() public {
        address alice = makeAddr("alice");
        // Fund the pool by sending ETH directly to the contract (receive()).
        vm.deal(address(this), REWARD_NATIVE);
        (bool ok,) = address(badge).call{value: REWARD_NATIVE}("");
        assertTrue(ok);

        uint256 before = alice.balance;
        _claim(idNative, alice);
        assertEq(alice.balance, before + REWARD_NATIVE);
    }

    function test_Reward_Native_ShortfallDoesNotRevert() public {
        address alice = makeAddr("alice");
        // Contract has no ETH.
        assertEq(address(badge).balance, 0);

        uint256 before = alice.balance;
        AchievementBadge.Voucher memory v = _voucher(idNative, alice, _nextHash());
        vm.expectEmit(true, true, false, true);
        emit RewardShortfall(alice, idNative, NATIVE, REWARD_NATIVE);
        badge.claimAchievement(v, _sign(SIGNER_PK, v));

        assertEq(badge.ownerOf(1), alice);
        assertTrue(badge.hasClaimed(idNative, alice));
        assertEq(alice.balance, before);
    }

    // ---------------------------------------------------------------------------------------------
    // fundPool / withdrawPool access control
    // ---------------------------------------------------------------------------------------------

    function test_FundPool_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        badge.fundPool(address(token), 1);
    }

    function test_WithdrawPool_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        badge.withdrawPool(address(token), 1, stranger);
    }

    function test_WithdrawPool_ERC20() public {
        token.approve(address(badge), REWARD_ERC20);
        badge.fundPool(address(token), REWARD_ERC20);

        address dest = makeAddr("dest");
        vm.expectEmit(true, false, false, true);
        emit PoolWithdrawn(address(token), REWARD_ERC20, dest);
        badge.withdrawPool(address(token), REWARD_ERC20, dest);
        assertEq(token.balanceOf(dest), REWARD_ERC20);
    }

    function test_WithdrawPool_Native() public {
        vm.deal(owner, REWARD_NATIVE);
        badge.fundPool{value: REWARD_NATIVE}(NATIVE, REWARD_NATIVE);

        address payable dest = payable(makeAddr("dest"));
        uint256 before = dest.balance;
        badge.withdrawPool(NATIVE, REWARD_NATIVE, dest);
        assertEq(dest.balance, before + REWARD_NATIVE);
    }

    function test_FundPool_Native_RevertsOnValueMismatch() public {
        vm.deal(owner, 1 ether);
        vm.expectRevert(AchievementBadge.NativeFundingMismatch.selector);
        badge.fundPool{value: 0.5 ether}(NATIVE, 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Soulbound enforcement
    // ---------------------------------------------------------------------------------------------

    function test_Soulbound_TransferFromReverts() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        vm.prank(alice);
        vm.expectRevert(AchievementBadge.TransferNotAllowed.selector);
        badge.transferFrom(alice, stranger, tokenId);
    }

    function test_Soulbound_SafeTransferFromReverts() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        vm.prank(alice);
        vm.expectRevert(AchievementBadge.TransferNotAllowed.selector);
        badge.safeTransferFrom(alice, stranger, tokenId);
    }

    function test_Soulbound_SafeTransferFromWithDataReverts() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        vm.prank(alice);
        vm.expectRevert(AchievementBadge.TransferNotAllowed.selector);
        badge.safeTransferFrom(alice, stranger, tokenId, "");
    }

    function test_Soulbound_ApproveRevertsEvenForHolder() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        vm.prank(alice);
        vm.expectRevert(AchievementBadge.SoulboundTokenNoApprovals.selector);
        badge.approve(stranger, tokenId);
    }

    function test_Soulbound_SetApprovalForAllRevertsEvenForHolder() public {
        address alice = makeAddr("alice");
        _claim(idBasic, alice);
        vm.prank(alice);
        vm.expectRevert(AchievementBadge.SoulboundTokenNoApprovals.selector);
        badge.setApprovalForAll(stranger, true);
    }

    function test_Soulbound_MintThenBurnViaRevokeSucceeds() public {
        address alice = makeAddr("alice");
        // Mint (claim) works despite _update override...
        (uint256 tokenId,) = _claim(idBasic, alice);
        assertEq(badge.ownerOf(tokenId), alice);
        // ...and burn via revoke works too (must not hit TransferNotAllowed).
        badge.revokeBadge(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        badge.ownerOf(tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // revokeBadge
    // ---------------------------------------------------------------------------------------------

    function test_RevokeBadge_OnlyOwner() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        badge.revokeBadge(tokenId);
    }

    function test_RevokeBadge_ClearsStateButKeepsClaimCount() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        assertEq(badge.claimCount(idBasic), 1);

        vm.expectEmit(true, true, true, false);
        emit BadgeRevoked(tokenId, alice, idBasic);
        badge.revokeBadge(tokenId);

        // Token burned.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        badge.ownerOf(tokenId);
        // hasClaimed cleared, holder removed.
        assertFalse(badge.hasClaimed(idBasic, alice));
        assertEq(badge.holdersOfAchievement(idBasic).length, 0);
        // claimCount is INTENTIONALLY not decremented.
        assertEq(badge.claimCount(idBasic), 1);
    }

    function test_RevokeBadge_AllowsReclaimBySameWallet() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idBasic, alice);
        badge.revokeBadge(tokenId);

        // The (wallet, achievement) slot is genuinely reusable with a fresh eventHash.
        (uint256 newTokenId,) = _claim(idBasic, alice);
        assertTrue(badge.hasClaimed(idBasic, alice));
        assertEq(badge.ownerOf(newTokenId), alice);
        // claimCount now 2 (edition numbers monotonic; original edition permanently consumed).
        assertEq(badge.claimCount(idBasic), 2);
        assertEq(badge.tokenMeta(newTokenId).edition, 2);
    }

    function test_RevokeBadge_SwapPopKeepsRemainingHolders() public {
        address a = makeAddr("holderA");
        address b = makeAddr("holderB");
        address c = makeAddr("holderC");
        _claim(idBasic, a); // tokenId 1
        (uint256 tokenB,) = _claim(idBasic, b); // tokenId 2 (the middle one)
        _claim(idBasic, c); // tokenId 3

        badge.revokeBadge(tokenB);

        address[] memory holders = badge.holdersOfAchievement(idBasic);
        assertEq(holders.length, 2);
        // a and c still present (order not guaranteed due to swap-and-pop); b gone.
        bool hasA;
        bool hasC;
        for (uint256 i = 0; i < holders.length; ++i) {
            if (holders[i] == a) hasA = true;
            if (holders[i] == c) hasC = true;
            assertTrue(holders[i] != b);
        }
        assertTrue(hasA && hasC);
        assertFalse(badge.hasClaimed(idBasic, b));
        assertTrue(badge.hasClaimed(idBasic, a));
        assertTrue(badge.hasClaimed(idBasic, c));
    }

    // ---------------------------------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------------------------------

    function test_AchievementsOfWallet() public {
        address alice = makeAddr("alice");
        _claim(idBasic, alice);
        _claim(idCapped, alice);
        uint256[] memory owned = badge.achievementsOfWallet(alice);
        assertEq(owned.length, 2);
        assertEq(owned[0], idBasic);
        assertEq(owned[1], idCapped);
    }

    function test_PerAppBadgeCount() public {
        address alice = makeAddr("alice");
        // idBasic & idCapped & idErc20 & idNative are app1; idPrereq is app2 (needs idBasic).
        _claim(idBasic, alice);
        _claim(idCapped, alice);
        _claim(idPrereq, alice);

        assertEq(badge.perAppBadgeCount(alice, "app1"), 2);
        assertEq(badge.perAppBadgeCount(alice, "app2"), 1);
        assertEq(badge.perAppBadgeCount(alice, "nope"), 0);
    }

    function test_TokenMeta_RevertsOnNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
        badge.tokenMeta(999);
    }

    function test_TokenMeta_ReturnsCorrectData() public {
        address alice = makeAddr("alice");
        (uint256 tokenId,) = _claim(idCapped, alice);
        AchievementBadge.TokenMeta memory meta = badge.tokenMeta(tokenId);
        assertEq(meta.achievementId, idCapped);
        assertEq(meta.edition, 1);
        assertEq(meta.earnedAt, block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------
    // setVoucherSigner
    // ---------------------------------------------------------------------------------------------

    function test_SetVoucherSigner_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        badge.setVoucherSigner(stranger);
    }

    function test_SetVoucherSigner_OldSignerRejectedNewSignerAccepted() public {
        address alice = makeAddr("alice");
        uint256 newPk = 0xC0FFEE;
        address newSigner = vm.addr(newPk);

        vm.expectEmit(true, true, false, false);
        emit VoucherSignerUpdated(signer, newSigner);
        badge.setVoucherSigner(newSigner);
        assertEq(badge.voucherSigner(), newSigner);

        // Voucher signed by the OLD signer now fails.
        AchievementBadge.Voucher memory v = _voucher(idBasic, alice, _nextHash());
        bytes memory oldSig = _sign(SIGNER_PK, v);
        vm.expectRevert(AchievementBadge.InvalidVoucherSignature.selector);
        badge.claimAchievement(v, oldSig);

        // Voucher signed by the NEW signer succeeds.
        AchievementBadge.Voucher memory v2 = _voucher(idBasic, alice, _nextHash());
        badge.claimAchievement(v2, _sign(newPk, v2));
        assertTrue(badge.hasClaimed(idBasic, alice));
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: randomized claim order across wallets/achievements; invariants hold
    // ---------------------------------------------------------------------------------------------

    function testFuzz_RandomizedClaims_NoInvariantBreaks(uint256 seed) public {
        // A small capped achievement + reuse of the uncapped/prereq ones from setUp.
        uint256 capN = 3;
        uint256 idFuzzCap =
            registry.createAchievement(_def("app1", "fzcap", 1, capN, address(0), 0, new uint256[](0)));

        uint256[] memory pool = new uint256[](3);
        pool[0] = idBasic; // uncapped, no prereq
        pool[1] = idFuzzCap; // capped
        pool[2] = idPrereq; // needs idBasic

        uint256 iters = 20;
        address[5] memory wallets = [
            makeAddr("fw0"),
            makeAddr("fw1"),
            makeAddr("fw2"),
            makeAddr("fw3"),
            makeAddr("fw4")
        ];

        uint256 successfulCapClaims;

        for (uint256 i = 0; i < iters; ++i) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            address w = wallets[rnd % 5];
            uint256 aid = pool[(rnd >> 8) % 3];

            AchievementBadge.Voucher memory v = _voucher(aid, w, _nextHash());
            bytes memory sig = _sign(SIGNER_PK, v);

            // Predict whether this claim should succeed and try/catch accordingly.
            bool alreadyHeld = badge.hasClaimed(aid, w);
            bool prereqOk = aid != idPrereq || badge.hasClaimed(idBasic, w);
            bool capOk = aid != idFuzzCap || badge.claimCount(idFuzzCap) < capN;

            try badge.claimAchievement(v, sig) {
                // Should only succeed when all gates pass.
                assertTrue(!alreadyHeld && prereqOk && capOk, "unexpected claim success");
                assertTrue(badge.hasClaimed(aid, w));
                if (aid == idFuzzCap) ++successfulCapClaims;
            } catch {
                // Should only fail when some gate blocked it.
                assertTrue(alreadyHeld || !prereqOk || !capOk, "unexpected claim failure");
            }

            // Invariant: capped achievement never over-issued.
            assertLe(badge.claimCount(idFuzzCap), capN);
        }

        // claimCount for the capped one matches the number of successful cap claims we observed.
        assertEq(badge.claimCount(idFuzzCap), successfulCapClaims);
        assertLe(successfulCapClaims, capN);
    }
}
