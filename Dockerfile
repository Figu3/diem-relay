FROM oven/bun:1.3-alpine

WORKDIR /app

COPY package.json bun.lockb* ./
RUN bun install --frozen-lockfile --production

COPY src/ src/

RUN mkdir -p data

EXPOSE 3100

CMD ["bun", "run", "src/index.ts"]
