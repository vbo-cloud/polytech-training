FROM node:24.19.0-alpine
WORKDIR /app
COPY package*.json .
RUN npm ci --omit=dev
COPY . .
# The node image already ships an unprivileged "node" user (uid 1000). Placed
# after npm ci so node_modules stays owned by root.
USER node
EXPOSE 4000
CMD ["node", "server.js"]
