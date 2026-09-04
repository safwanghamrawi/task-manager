# syntax=docker/dockerfile:1.7

###############################################################################
# Stage 1 - deps: install node_modules from the lockfile only. Cached until a
# dependency actually changes.
###############################################################################
FROM node:22-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./
# `npm ci` is reproducible and fails if the lockfile is out of sync with
# package.json — exactly what a build pipeline wants.
RUN npm ci

###############################################################################
# Stage 2 - dev: hot-reloading Next.js dev server. Source is bind-mounted over
# /app by docker-compose.override.yml, while node_modules stays in the image.
###############################################################################
FROM node:22-alpine AS dev

WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0

COPY --from=deps /app/node_modules ./node_modules
COPY . .

EXPOSE 3000

CMD ["npm", "run", "dev"]

###############################################################################
# Stage 3 - builder: lint, typecheck and compile the standalone server.
###############################################################################
FROM node:22-alpine AS builder

WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* values are inlined into the client bundle at build time, so the
# API URL has to be known here. It defaults to the relative /api, which works
# for any hostname behind Traefik — no rebuild per environment.
ARG NEXT_PUBLIC_API_BASE_URL=/api
ENV NEXT_PUBLIC_API_BASE_URL=${NEXT_PUBLIC_API_BASE_URL}

RUN npm run lint && npm run typecheck && npm run build

###############################################################################
# Stage 4 - runner: only the standalone output and static assets. No source,
# no npm, no dev dependencies.
###############################################################################
FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Strip the package managers the base image ships. Each bundles its own
# dependency tree, and that tree is where CVEs keep landing — npm's vendored
# `tar` is what failed this build's CRITICAL gate, and it was never reachable
# from the application.
#
# `node server.js` needs none of them: the standalone output already carries
# every module Next traced. Removing them makes the "no npm" claim above true
# and retires a whole recurring class of finding rather than chasing each one.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack \
           /opt/yarn-v* \
           /usr/local/bin/yarn \
           /usr/local/bin/yarnpkg

# node:alpine already ships an unprivileged `node` user (uid 1000).
COPY --from=builder --chown=root:root /app/.next/standalone ./
COPY --from=builder --chown=root:root /app/.next/static ./.next/static
COPY --from=builder --chown=root:root /app/public ./public

USER node

EXPOSE 3000

# Checks only that this server is answering — see src/app/healthz/route.ts for
# why it deliberately does not depend on the backend.
HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 \
    CMD wget --quiet --spider --tries=1 http://127.0.0.1:3000/healthz || exit 1

# `node server.js` runs as PID 1 and Next's standalone server handles SIGTERM
# by closing the listener and draining in-flight requests.
CMD ["node", "server.js"]
