FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY src/ src/
ENV PORT=3000 NODE_ENV=production
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
