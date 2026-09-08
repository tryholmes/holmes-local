# holmes-mcp-__NAME__

A read only MCP server for Holmes, in TypeScript.

```sh
npm install
npm run build
holmes-sdk mcp add __NAME__ -- node "$PWD/dist/index.js"
holmes-sdk mcp lint __NAME__
```

Then reference it from a playbook manifest:

```json
"mcpServers": ["__NAME__"]
```

Edit `src/index.ts`. Keep tool names as reads (`search_*`, `get_*`, `list_*`)
and keep `readOnlyHint: true`, or Holmes will not offer them. Details in
`../README.md`.
