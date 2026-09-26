# -- Build Stage ----------------------------------------------------
FROM node:20-alpine AS base
WORKDIR /app
COPY package*.json ./

FROM base AS development
RUN npm install --legacy-peer-deps
COPY . .
EXPOSE 3000 3001
CMD ["npx", "tsx", "watch", "src/index.ts"]

FROM base AS build
RUN npm install --legacy-peer-deps --only=production
COPY . .
RUN npm run build

FROM node:20-alpine AS production
WORKDIR /app
ENV NODE_ENV=production

# Install curl for healthcheck
RUN apk add --no-cache curl

COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json .

EXPOSE 3000 3001
HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
  CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
