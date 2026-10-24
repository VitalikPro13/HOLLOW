FROM node:22-alpine

WORKDIR /app
COPY package.json package-lock.json ./
# firebase-admin is optional and a self-hosted relay has no Firebase account,
# so the image carries only the UnifiedPush sender, at the lockfile's versions.
RUN npm ci --omit=optional --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY index.js fcm.js unifiedpush.js ./

USER node
ENV PUSH_PORT=3001
CMD ["node", "index.js"]
