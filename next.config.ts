import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    adapterPath: `${import.meta.dirname}/node_modules/@apphosting/adapter-nextjs/dist/index.cjs`,
    cacheComponents: true,
  },
};

export default nextConfig;
