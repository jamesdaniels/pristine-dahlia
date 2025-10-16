import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    adapterPath: "/Users/jamesdaniels/Code/firebase-framework-tools/packages/@apphosting/adapter-nextjs/dist/index.cjs",
    cacheComponents: true,
  },
};

export default nextConfig;
