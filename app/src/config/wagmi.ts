import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { base } from "wagmi/chains";
import { http } from "wagmi";

const alchemyUrl =
  process.env.NEXT_PUBLIC_ALCHEMY_URL ??
  "https://base-mainnet.g.alchemy.com/v2/demo";

export const config = getDefaultConfig({
  appName: "DIEM Staking",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "placeholder",
  chains: [base],
  transports: {
    [base.id]: http(alchemyUrl),
  },
  ssr: true,
});
