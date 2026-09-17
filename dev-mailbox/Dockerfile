# Development mailbox. Light dependencies (MySQL driver, ioredis for the
# Gateway trace, kafkajs to resolve padrons) and a single file.
FROM node:22-alpine
WORKDIR /app

COPY package.json ./
# No package-lock: it is a one-file development tool, and one more lock to
# maintain buys nothing. `npm ci` does not apply here.
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

EXPOSE 4300
CMD ["node", "server.js"]
