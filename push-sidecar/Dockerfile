FROM node:22-alpine

WORKDIR /app
COPY package.json ./
# firebase-admin is optional and a self-hosted relay has no Firebase account,
# so the image carries only the UnifiedPush sender.
RUN npm install --omit=optional --omit=dev && npm cache clean --force
COPY index.js unifiedpush.js ./

USER node
ENV PUSH_PORT=3001
CMD ["node", "index.js"]
