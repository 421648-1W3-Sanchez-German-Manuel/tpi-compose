# Buzon de desarrollo. Una sola dependencia (el driver de MySQL) y un archivo.
FROM node:22-alpine
WORKDIR /app

COPY package.json ./
# Sin package-lock: es una herramienta de desarrollo de un archivo, y un lock
# mas para mantener no compra nada. `npm ci` aca no aplica.
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

EXPOSE 4300
CMD ["node", "server.js"]
