FROM bitnami/kubectl:latest AS kubectl
FROM node:20-alpine
COPY --from=kubectl /opt/bitnami/kubectl/bin/kubectl /usr/local/bin/kubectl
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY src/ src/
ENV K8S_NAMESPACE=demo CHAOS_INTENSITY=0.3 CHAOS_INTERVAL_MS=30000
CMD ["node", "src/chaos.js"]
