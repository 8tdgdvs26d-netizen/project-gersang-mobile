FROM node:22-bookworm-slim
WORKDIR /app
COPY . /app
ENV PORT=10000
ENV DB_PATH=/data/first-playable.sqlite
VOLUME ["/data"]
EXPOSE 10000
CMD ["node", "server.mjs"]
