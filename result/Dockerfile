FROM node:24
WORKDIR /source/result
COPY package*.json .
RUN npm ci --legacy-peer-deps --no-optional --omit=dev
COPY . .
CMD ["node", "server.js"]
