"use client";

import { useEffect, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { base } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";

const CHAIN_ID = 8453;
const registryAddress = (deployedContracts as any)[CHAIN_ID]?.AchievementRegistry?.address;
const badgeAddress = (deployedContracts as any)[CHAIN_ID]?.AchievementBadge?.address;

const Home: NextPage = () => {
  // <Address/> resolves ENS via wagmi, which requires a real WagmiProvider — not present
  // during the static prerender pass. Mount-gate it the same way ScaffoldEthAppWithProviders does.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  return (
    <div className="flex items-center flex-col grow pt-10">
      <div className="px-5 max-w-2xl text-center">
        <h1 className="text-center">
          <span className="block text-4xl font-bold">Clawd Achievements</span>
          <span className="block text-lg mt-2 opacity-70">
            Cross-app onchain achievement system — soulbound NFT badges on Base
          </span>
        </h1>

        <p className="text-left text-base mt-8">
          This project is a two-contract system deployed on Base mainnet: an owner-curated{" "}
          <code className="italic bg-base-300 font-bold">AchievementRegistry</code> holding achievement definitions
          (tier, supply cap, prerequisites, bundled rewards), and a soulbound{" "}
          <code className="italic bg-base-300 font-bold">AchievementBadge</code> ERC-721 contract that mints badges on
          presentation of an EIP-712-signed voucher from a trusted backend. See the repository README for the full
          integration guide, ABI, and a TypeScript voucher-signing example.
        </p>
      </div>

      <div className="grow bg-base-300 w-full mt-16 px-8 py-12">
        <div className="flex justify-center items-center gap-8 flex-col md:flex-row max-w-3xl mx-auto">
          <div className="flex flex-col bg-base-100 border border-base-300 px-8 py-8 text-center items-center flex-1 gap-2">
            <p className="font-semibold m-0">AchievementRegistry</p>
            {mounted && registryAddress && <Address address={registryAddress} chain={base} />}
          </div>
          <div className="flex flex-col bg-base-100 border border-base-300 px-8 py-8 text-center items-center flex-1 gap-2">
            <p className="font-semibold m-0">AchievementBadge</p>
            {mounted && badgeAddress && <Address address={badgeAddress} chain={base} />}
          </div>
        </div>
      </div>
    </div>
  );
};

export default Home;
