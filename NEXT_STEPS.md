# Next Steps / Known Limitations

## Must do before going live
- **Call `setVoucherSigner(<backend signer address>)`** on `AchievementBadge` from the owner
  wallet. It's currently the deployer's address as a placeholder.
- **Fund the reward pool** for any achievement with a bundled reward, before backend-issued
  vouchers for it start getting claimed (`fundPool` — see INTEGRATION.md §2).

## Known, documented, intentional design decisions (not bugs)
- `claimCount` is never decremented on `revokeBadge` — edition numbers are permanently retired,
  not reused, to avoid collisions if the same wallet re-claims later.
- `eventHash` replay protection is global across all achievements, not scoped per-achievement —
  your backend must generate globally-unique event identifiers.
- `setMaxSupply` + `lockSupplyCap` do not validate against the current claim count (the registry
  doesn't track claims — that lives in the badge contract). If you lower a cap below the number
  already issued and then lock it, no new badges can mint (correct), but this is a manual owner
  responsibility, not enforced on-chain. See `AchievementRegistry.sol` NatSpec on `setMaxSupply`.

## Cosmetic / out of scope for this bot
- **Favicon, logo, and OG image are still the default Scaffold-ETH 2 placeholder assets.**
  Image generation is outside this bot's capabilities; since the client is building their own
  frontend (Hub/claim UI/admin panel) in their own stack, this repo's own frontend is intentionally
  minimal (contract info only) and wasn't a priority to restyle. Swap `packages/nextjs/public/favicon.png`,
  `logo.svg`, and `thumbnail.jpg` whenever convenient.
- **Frontend is deliberately minimal** per the client's stated scope ("frontend beyond your
  standard debug pages" is explicitly out of scope) — no claim UI, no admin panel. The homepage
  just shows the project description and the two deployed contract addresses.

## Platform note (not a code issue)
- The leftclaw messages endpoint (`GET /api/job/{id}/messages`) returned `403 Forbidden` for this
  job before acceptance despite the worker wallet passing `isWorker()` on-chain and producing a
  valid signature — it worked normally after `acceptJob`. No messages had been posted, so this
  didn't affect scope in this case, but flagging it in case it affects future jobs where a client
  posts pre-acceptance scope changes.

## Audit disclosure
Two independent security reviews were run (EIP-712/signature/replay/domain-separation, and
soulbound/access-control/reentrancy/supply-cap-integrity). Both came back with **zero
Critical/High/Medium findings**. The Low/Info items that were actionable were fixed:
`ECDSA.recoverCalldata` (gas), zero-address guard on the constructor's initial signer, and a
32-item cap on the prerequisites array (defense-in-depth against a fat-fingered or compromised
owner creating an unclaimably expensive achievement). Two Low/Info items were left as documented
behavior rather than code changes (see above): the `setMaxSupply`/`lockSupplyCap` ordering note,
and the unbounded `perAppBadgeCount`/`achievementsOfWallet` view-loop scalability note at very
large achievement counts (10,000+) — both are view-only, non-state-changing, and the contract's
events-first design gives the client's frontend a pagination-friendly alternative if it's ever needed.
