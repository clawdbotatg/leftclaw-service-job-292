# Clawd Achievements

Cross-app onchain achievement system on Base — soulbound NFT badges, some with capped supply,
some bundled with token rewards, claimed via EIP-712-signed vouchers so users pay no gas.

**Live URL:** https://bafybeif2txaxsu46mtz74lr6gfy3p3czgiojlzxnje7a2tdchg6ly334qe.ipfs.community.bgipfs.com/

This job's scope is **contracts, tests, and Base mainnet deployment only** — the client builds
and operates their own frontend (Hub, claim UI, admin panel) in their own stack. The frontend in
this repo is intentionally minimal (project info + deployed contract addresses only, no
claim/admin UI) to match that scope.

## Contracts (Base mainnet, chain id 8453)

| Contract | Address | Basescan |
|---|---|---|
| `AchievementRegistry` | [`0xE6731a953268EC0bDc73dF01C7d73Dd09C28207C`](https://basescan.org/address/0xE6731a953268EC0bDc73dF01C7d73Dd09C28207C#code) | Verified ✅ |
| `AchievementBadge` | [`0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa`](https://basescan.org/address/0x79350955160a24bE0FA18243Af6FA5F53CBEcCCa#code) | Verified ✅ |

Both are `Ownable2Step`, owned directly by the client wallet (`0xf2c44aF68aE2a983d1331b2D3aEF3c516Ae4a0Fc`) —
set at construction, no `acceptOwnership()` call needed.

**→ See [`INTEGRATION.md`](./INTEGRATION.md) for the full integration guide: ABI surface, the exact
EIP-712 typed-data structure, and a working TypeScript (viem) example of signing a voucher and
submitting a claim transaction.**

## What each contract does

- **`AchievementRegistry`** — owner-curated catalogue of achievement definitions: appId, key,
  name, description, tier (Common/Rare/Legendary), image URI, supply cap (optionally
  permanently locked), bundled reward (ERC20 or native ETH), prerequisites (cross-app
  meta-achievements), hidden flag, active flag. One registry serves unlimited apps.
- **`AchievementBadge`** — strictly soulbound ERC-721. Mints on presentation of an EIP-712
  voucher signed by a designated backend signer (owner-rotatable), with permanent replay
  protection, supply-cap enforcement, prerequisite checks, and non-reverting bundled reward
  payout. Fully on-chain, base64-encoded `tokenURI` — no offchain metadata server. Every state
  change emits an event, so the client's own frontend can index everything via simple RPC reads,
  no subgraph required.

## Immediate next step for the client

Call `setVoucherSigner(<your backend's signer address>)` on `AchievementBadge` from the owner
wallet. It's currently seeded to the deployer's address as a placeholder so no vouchers can be
forged in the meantime — but no real vouchers will verify until you rotate it to your own key.

## Repository layout

```
packages/
  foundry/
    contracts/               AchievementRegistry.sol, AchievementBadge.sol, interfaces/
    script/DeployAchievements.s.sol
    test/                    67 passing unit + fuzz tests
  nextjs/                    minimal info page (see scope note above)
INTEGRATION.md                full integration guide for the client's backend
NEXT_STEPS.md                 known limitations / follow-up items
```

## Local development

```bash
cd packages/foundry
forge build
forge test --fuzz-runs 512
```

To redeploy or modify: edit `packages/foundry/contracts/`, then `yarn deploy --network base`
(reads `ALCHEMY_API_KEY` from a foundry keystore-based signer — see `packages/foundry/Makefile`).
Never use a public RPC (`mainnet.base.org` etc.) for deployment or contract calls.
