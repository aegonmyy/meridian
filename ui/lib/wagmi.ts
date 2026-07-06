import { createConfig, http } from "wagmi";
import { sepolia, arbitrumSepolia, baseSepolia, optimismSepolia } from "wagmi/chains";
import { injected, walletConnect } from "wagmi/connectors";

const wcProjectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID;

export const wagmiConfig = createConfig({
  chains: [sepolia, arbitrumSepolia, baseSepolia, optimismSepolia],
  connectors: [
    injected(),
    ...(wcProjectId ? [walletConnect({ projectId: wcProjectId })] : []),
  ],
  transports: {
    [sepolia.id]:          http(process.env.NEXT_PUBLIC_SEPOLIA_RPC),
    [arbitrumSepolia.id]:  http(process.env.NEXT_PUBLIC_ARB_SEPOLIA_RPC),
    [baseSepolia.id]:      http(process.env.NEXT_PUBLIC_BASE_SEPOLIA_RPC),
    [optimismSepolia.id]:  http(process.env.NEXT_PUBLIC_OP_SEPOLIA_RPC),
  },
});
