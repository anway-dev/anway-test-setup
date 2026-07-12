FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY src/ src/
ENV GATEWAY_URL=http://api-gateway:8080 RPS=10
CMD ["node", "src/simulator.js"]
