FROM node:24.19.0-alpine
WORKDIR /app
COPY package*.json .
RUN npm ci --omit=dev
COPY . .
CMD ["node", "server.js"]
