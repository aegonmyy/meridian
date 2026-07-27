import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Meridian: Cross-Chain Yield",
  description: "Automated cross-chain yield optimization powered by Chainlink CCIP",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={GeistSans.variable}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
