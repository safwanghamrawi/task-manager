import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Emits .next/standalone: a minimal server bundle with only the production
  // dependencies it actually traced. This is what keeps the runtime image
  // small and lets it run without node_modules or the npm CLI present.
  output: "standalone",

  // Fail the build on type or lint errors rather than shipping them.
  typescript: { ignoreBuildErrors: false },
  eslint: { ignoreDuringBuilds: false },

  // Do not advertise the framework version to the internet.
  poweredByHeader: false,

  reactStrictMode: true,
  compress: true,

  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
