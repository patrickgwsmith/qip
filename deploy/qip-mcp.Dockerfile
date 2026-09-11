# The repository contains a Go module as well as this dependency-free Node
# server. Use an explicit Node image so App Platform does not select the Go
# buildpack for qip-mcp.
FROM node:22-bookworm-slim

WORKDIR /app

COPY qip-mcp.mjs ./
COPY site/data/component-catalog.csv site/data/component-catalog.csv
COPY text/csv/content-recipe-to-browser-javascript.wasm text/csv/content-recipe-to-browser-javascript.wasm

CMD ["node", "qip-mcp.mjs", "--http", "--host", "0.0.0.0", "--port", "8080", "--origin", "https://qip.dev"]
