import { createConfig, http } from "wagmi";
import { base } from "wagmi/chains";
import { injected, coinbaseWallet } from "wagmi/connectors";

const alchemyUrl =
  process.env.NEXT_PUBLIC_ALCHEMY_URL ??
  "https://base-mainnet.g.alchemy.com/v2/demo";

export const config = createConfig({
  chains: [base],
  connectors: [
    injected(),
    coinbaseWallet({ appName: "DIEM Relay" }),
  ],
  transports: {
    [base.id]: http(alchemyUrl),
  },
  ssr: true,
});
