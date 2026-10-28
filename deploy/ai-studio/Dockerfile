# Targets: api (backend), worker (execution worker), web (nginx, SPA + /api proxy).
# Build context must be the repo root: workspace packages are linked via pnpm
# `workspace:*`.
#
# No `# syntax=` line on purpose: it would pull the build frontend from Docker Hub
# as an unpinned download. Needs Docker Engine 23+ (built-in BuildKit frontend).
#
# Only base image pulls, the Debian and pnpm installs and `pnpm fetch` reach the network;
# every RUN after the fetch is --network=none (tools/check-offline-build.mjs). Mirrors:
# the optional `npmrc` and `debian-sources` secrets (README "Air-gapped / offline install").

# Exact Node pin: engineStrict rejects any other version. Same value as `engines.node`.
FROM node:22.23.4-trixie-slim AS node-base

# pnpm via npm, not corepack: Node 25 and later no longer bundle corepack.
# Keep in sync with `packageManager`.
FROM node-base AS base
ENV PNPM_HOME=/pnpm \
    PATH="/pnpm:$PATH" \
    # husky needs the .git dir that the build context excludes
    HUSKY=0 \
    npm_config_store_dir=/pnpm/store \
    CI=true
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm install -g pnpm@10.17.0 --prefer-offline
WORKDIR /app

# Base of the api and worker images: Debian security fixes at build time, tini as PID 1
# to pass SIGTERM on to Node, and no package managers at runtime. --error-on=any fails the
# build when any repository fails to update, instead of upgrading without it.
FROM node-base AS runtime-base
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=secret,id=debian-sources,target=/etc/apt/sources.list.d/debian.sources \
    apt-get update --error-on=any \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
       /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
       /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
       /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*
# tsx otherwise creates a cache dir under /tmp at start-up, which a read-only root filesystem refuses.
ENV NODE_ENV=production \
    TSX_DISABLE_CACHE=1
# Each app's tsconfig.json extends ../../tsconfig.base.json, and tsx reads it at start-up.
COPY tsconfig.base.json /app/
ENTRYPOINT ["/usr/bin/tini", "--"]

FROM base AS source
COPY pnpm-lock.yaml pnpm-workspace.yaml ./
# `useNodeVersion` would make pnpm download Node for lifecycle scripts, fatal with no network.
# Stripped in the image only, twice because `COPY . .` restores the file.
RUN --network=none sed -i '/^useNodeVersion:/d' pnpm-workspace.yaml
# The store stays in this layer, not in a cache mount: the api and worker installs below
# start from an empty node_modules and read every package from it offline.
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    pnpm fetch
COPY . .
RUN --network=none sed -i '/^useNodeVersion:/d' pnpm-workspace.yaml

# @workflowbuilder/temporal resolves to ./dist, which .dockerignore keeps out of the
# context; building it needs devDependencies (tsup), so only the result is carried over.
FROM source AS package-build
RUN --network=none pnpm install --frozen-lockfile --offline --filter @workflowbuilder/temporal...
RUN --network=none pnpm build:temporal

# One production install per image, from an empty node_modules, so each ships only its own
# app's dependency closure. --ignore-scripts skips the workspace `prepare` scripts (husky, tsup).
FROM source AS api-deps
RUN --network=none rm -rf node_modules \
    && pnpm install --frozen-lockfile --offline --prod --ignore-scripts --filter @workflow-builder/backend...

FROM source AS worker-deps
RUN --network=none rm -rf node_modules \
    && pnpm install --frozen-lockfile --offline --prod --ignore-scripts --filter @workflow-builder/execution-worker...

# VITE_BACKEND_URL is baked at build time; empty = same-origin /api,
# proxied by the web target's nginx.
FROM source AS frontend-build
ARG VITE_BACKEND_URL=
RUN --network=none pnpm install --frozen-lockfile --offline --filter @workflow-builder/ai-studio...
RUN --network=none VITE_BACKEND_URL=$VITE_BACKEND_URL pnpm build:ai-studio

# The apps run their TS sources through tsx; the worker's workflow bundler also reads them at start-up.
FROM runtime-base AS api
COPY --from=api-deps /app/node_modules /app/node_modules
COPY --from=api-deps /app/packages /app/packages
COPY --from=package-build /app/packages/temporal/dist /app/packages/temporal/dist
COPY --from=api-deps /app/apps/backend /app/apps/backend
WORKDIR /app/apps/backend
ENV HOST=0.0.0.0 \
    PORT=3001
EXPOSE 3001
# Numeric (the base image's `node` user), so Kubernetes runAsNonRoot can verify it.
USER 1000:1000
CMD ["node", "--import", "tsx", "src/server.ts"]

FROM runtime-base AS worker
COPY --from=worker-deps /app/node_modules /app/node_modules
COPY --from=worker-deps /app/packages /app/packages
COPY --from=package-build /app/packages/temporal/dist /app/packages/temporal/dist
COPY --from=worker-deps /app/apps/execution-worker /app/apps/execution-worker
WORKDIR /app/apps/execution-worker
USER 1000:1000
CMD ["node", "--import", "tsx", "src/engines/temporal/worker.ts"]

FROM nginx:1.31-alpine AS web
COPY deploy/ai-studio/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY deploy/ai-studio/nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=frontend-build /app/dist/apps/ai-studio /usr/share/nginx/html
