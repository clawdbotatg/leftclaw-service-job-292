# Clawd Achievements — Integration Guide

Everything a Next.js/Node backend needs to (1) manage achievement definitions, (2) sign claim
vouchers, and (3) submit claim transactions on behalf of users, without gas cost to them.

## Contracts (Base mainnet, chain id 8453)

| Contract | Address | Basescan |
|---|---|---|
| `AchievementRegistry` | `0xE6731a953268EC0bDc73dF01C7d73Dd09C28207C` | https://basescan.org/address/0xE6731a953268EC0bDc73dF01C7d73Dd09C28207C#code |
| `AchievementBadge` | `0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa` | https://basescan.org/address/0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa#code |

Both contracts are `Ownable2Step`, owned directly by your wallet (`0xf2c44aF68aE2a983d1331b2D3aEF3c516Ae4a0Fc`) —
no `acceptOwnership()` call is needed, ownership was set at construction.

Full ABIs are in the repo at `packages/nextjs/contracts/deployedContracts.ts` (auto-generated,
includes every function/event/error selector) and in the verified source on Basescan.

**Before going live:** call `setVoucherSigner(<your backend signer address>)` on `AchievementBadge`
from the owner wallet. It's currently seeded to the deployer's address as a placeholder — no
vouchers can be forged in the meantime, but no real vouchers will verify until you rotate it.

---

## 1. Managing achievement definitions (`AchievementRegistry`)

All owner-only, called from your admin panel/backend with the owner wallet.

```solidity
struct AchievementDef {
    string appId;              // your app's namespace, e.g. "clawd-tetris"
    string key;                // stable machine key unique within appId, e.g. "first_win"
    string name;                // display name
    string description;
    uint8 tier;                 // 1 = Common, 2 = Rare, 3 = Legendary
    string imageURI;             // ipfs://, https://, or data: URI for badge artwork
    uint256 maxSupply;           // 0 = uncapped
    bool capLocked;              // true = maxSupply can NEVER change again (one-way)
    address rewardToken;         // address(0) = no reward, 0xEeee...EEeE = native ETH, else ERC20
    uint256 rewardAmount;
    uint256[] prerequisites;     // achievementIds the wallet must already hold (max 32)
    bool hidden;                 // display hint only, no on-chain enforcement
    bool active;                 // false = claims blocked, existing badges unaffected
}
```

```solidity
function createAchievement(AchievementDef calldata def) external onlyOwner returns (uint256 id);
function editAchievement(uint256 id, string calldata name, string calldata description, uint8 tier,
    string calldata imageURI, address rewardToken, uint256 rewardAmount,
    uint256[] calldata prerequisites, bool hidden) external onlyOwner;
function setMaxSupply(uint256 id, uint256 newMaxSupply) external onlyOwner;   // reverts if capLocked
function lockSupplyCap(uint256 id) external onlyOwner;                        // one-way, permanent
function deactivateAchievement(uint256 id) external onlyOwner;
function activateAchievement(uint256 id) external onlyOwner;

function getAchievement(uint256 id) external view returns (AchievementDef memory);
function exists(uint256 id) external view returns (bool);
function totalAchievements() external view returns (uint256);
function getPrerequisites(uint256 id) external view returns (uint256[] memory);
```

**Native ETH / no-reward convention:** `rewardToken == address(0)` means "no reward." To pay
native ETH instead of an ERC20, set `rewardToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`
(the standard Aave/Curve placeholder for native ETH) — this is a fixed constant, exposed on the
badge contract as `AchievementBadge.NATIVE_ETH_SENTINEL`.

**Prerequisites must already exist** (id < the current achievement count) at creation time —
you can't forward-reference an achievement that doesn't exist yet. This makes the prerequisite
graph acyclic by construction.

`AchievementCreated` / `AchievementEdited` / `AchievementSupplyUpdated` / `AchievementCapLocked` /
`AchievementActiveStatusChanged` events cover every state change — index these for your admin
panel and Hub instead of polling.

---

## 2. Funding the reward pool (`AchievementBadge`)

The "pool" is simply this contract's own token/ETH balance — there's no separate ledger.

```solidity
function fundPool(address token, uint256 amount) external payable onlyOwner;
// ERC20: approve the badge contract for `amount` first, then call fundPool(tokenAddr, amount).
// Native ETH: call fundPool(NATIVE_ETH_SENTINEL, amount) with msg.value == amount,
//             OR just send ETH directly to the contract address (receive() accepts it).

function withdrawPool(address token, uint256 amount, address to) external onlyOwner;
```

If a claim's reward can't be paid (pool underfunded, or a misbehaving ERC20 transfer fails), the
**badge still mints** and a `RewardShortfall(recipient, achievementId, token, amount)` event fires
instead of `RewardPaid`. A claim never reverts due to reward-payout failure — fund the pool and
the next claim for that achievement will succeed normally; the missed reward is not automatically
retried or paid retroactively.

---

## 3. The EIP-712 voucher — exact typed-data structure

Domain (must match exactly or signatures will fail to recover):

```ts
const domain = {
  name: "AchievementBadge",
  version: "1",
  chainId: 8453,
  verifyingContract: "0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa",
} as const;

const types = {
  Voucher: [
    { name: "recipient", type: "address" },
    { name: "achievementId", type: "uint256" },
    { name: "eventHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
} as const;
```

| Field | Type | Meaning |
|---|---|---|
| `recipient` | `address` | Wallet that receives the badge. The contract mints here, **never** to `msg.sender` of the claim tx — this is what lets your backend submit the transaction and pay gas on the user's behalf. |
| `achievementId` | `uint256` | The achievement being claimed (from `AchievementRegistry`). |
| `eventHash` | `bytes32` | **Must be globally unique across every voucher you ever sign, for any achievement.** Replay protection is a single global mapping, not scoped per-achievement — reusing an `eventHash` (even for a different achievement) will revert on the second use. Derive it deterministically from your own event/action id, e.g. `keccak256(abi.encodePacked("clawd-tetris", userId, "first_win", timestamp))`. |
| `deadline` | `uint256` | Unix timestamp. Voucher is valid while `block.timestamp <= deadline`. |

**Signer:** the address recovered from the signature must equal the badge contract's current
`voucherSigner` (owner-settable via `setVoucherSigner`). Rotating the signer immediately
invalidates all outstanding vouchers signed by the old key.

---

## 4. TypeScript example — signing a voucher and submitting the claim (viem)

```ts
import { createWalletClient, createPublicClient, http, keccak256, toBytes, encodePacked } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

const BADGE_ADDRESS = "0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa" as const;
const NATIVE_ETH_SENTINEL = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" as const;

// This key belongs to your BACKEND (the `voucherSigner` on the badge contract).
// It does NOT need ETH — it only signs, it doesn't submit transactions.
const signerAccount = privateKeyToAccount(process.env.VOUCHER_SIGNER_PRIVATE_KEY as `0x${string}`);

// This key submits the actual on-chain transaction and pays gas. It can be the
// same key as the signer, or a separate relayer/gas wallet — the contract only
// checks the voucher's signature, not who calls claimAchievement.
const relayerAccount = privateKeyToAccount(process.env.RELAYER_PRIVATE_KEY as `0x${string}`);

const publicClient = createPublicClient({ chain: base, transport: http(process.env.ALCHEMY_RPC_URL) });
const walletClient = createWalletClient({ account: relayerAccount, chain: base, transport: http(process.env.ALCHEMY_RPC_URL) });

const domain = {
  name: "AchievementBadge",
  version: "1",
  chainId: base.id,
  verifyingContract: BADGE_ADDRESS,
} as const;

const types = {
  Voucher: [
    { name: "recipient", type: "address" },
    { name: "achievementId", type: "uint256" },
    { name: "eventHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

async function issueAchievement(recipient: `0x${string}`, achievementId: bigint, uniqueEventId: string) {
  const eventHash = keccak256(toBytes(uniqueEventId)); // MUST be unique across ALL vouchers ever signed
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 30); // 30 min validity

  const voucher = { recipient, achievementId, eventHash, deadline };

  // 1. Backend signs the voucher (off-chain, no gas).
  const signature = await signerAccount.signTypedData({
    domain,
    types,
    primaryType: "Voucher",
    message: voucher,
  });

  // 2. Relayer submits the claim on-chain, paying gas so the user doesn't have to.
  const hash = await walletClient.writeContract({
    address: BADGE_ADDRESS,
    abi: badgeAbi, // import from packages/nextjs/contracts/deployedContracts.ts
    functionName: "claimAchievement",
    args: [voucher, signature],
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return receipt;
}
```

Reading badge state for your Hub/UI (no indexer needed — everything's a view call or an event):

```ts
const heldAchievements = await publicClient.readContract({
  address: BADGE_ADDRESS,
  abi: badgeAbi,
  functionName: "achievementsOfWallet",
  args: [userAddress],
}); // uint256[]

const remaining = await publicClient.readContract({
  address: BADGE_ADDRESS,
  abi: badgeAbi,
  functionName: "remainingSupply",
  args: [achievementId],
}); // uint256, or type(uint256).max sentinel meaning uncapped
```

---

## 5. Errors you may see from `claimAchievement` (custom errors, not revert strings)

| Error | Cause |
|---|---|
| `VoucherExpired()` | `block.timestamp > deadline` |
| `EventHashAlreadyConsumed()` | This `eventHash` was already used (global, not per-achievement) |
| `InvalidVoucherSignature()` | Signature doesn't recover to the current `voucherSigner` |
| `AchievementNotActive()` | The achievement (or the id itself) doesn't exist, or `active == false` |
| `AlreadyClaimed()` | `recipient` already holds this achievement |
| `PrerequisiteNotMet(uint256 prereqId)` | `recipient` is missing a required prerequisite badge |
| `SupplyCapExceeded()` | `maxSupply` reached for this achievement |

Decode these client-side with viem's `decodeErrorResult` against the badge ABI, or catch the
revert reason directly — they're standard Solidity custom errors, not strings.

---

## 6. Soulbound behavior

Badges can never be transferred or approved for transfer — `transferFrom`, both
`safeTransferFrom` overloads, `approve`, and `setApprovalForAll` all revert unconditionally,
including for the token's own holder. There is no admin switch anywhere that can re-enable
transfers. The only way a badge leaves a wallet is `revokeBadge(tokenId)` (owner-only, burns the
token and frees the wallet+achievement slot for a corrected re-claim — the original edition number
is retired permanently, not reused, and `claimCount`/supply accounting is never decremented).
