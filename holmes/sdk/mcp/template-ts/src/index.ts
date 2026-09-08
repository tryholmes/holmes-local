#!/usr/bin/env node
// Holmes MCP server template (TypeScript).
//
// Two things matter for Holmes specifically:
//   1. Every tool Holmes may use must set annotations.readOnlyHint = true and
//      have a name that reads as a read (search_*, get_*, list_*, find_*).
//      Anything else is filtered out before the model sees it. See ../README.md.
//   2. A playbook manifest opts into this server by listing its mcp.json name
//      in "mcpServers". Built in playbooks never see it.
//
// Run:  npm install && npm run build
// Wire: holmes-sdk mcp add __NAME__ -- node /abs/path/to/dist/index.js
// Lint: holmes-sdk mcp lint __NAME__

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({ name: "holmes-mcp-__NAME__", version: "0.1.0" });

// ---------------------------------------------------------------------------
// Holmes context helper. Holmes serves its own read only MCP endpoint on
// loopback when the user turns on "Share screen context with local MCP
// clients" in Settings. Returns null when that is off, so tools keep working.
// ---------------------------------------------------------------------------

type ScreenContext = {
  appName?: string;
  windowTitle?: string;
  summary?: string;
  visibleText?: string;
  visibleTextConfidence?: string;
};

async function holmesScreenContext(): Promise<ScreenContext | null> {
  try {
    const res = await fetch("http://127.0.0.1:5767/mcp", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "get_screen_context", arguments: {} },
      }),
      signal: AbortSignal.timeout(1500),
    });
    if (!res.ok) return null;
    const json = (await res.json()) as any;
    const text = json?.result?.content?.[0]?.text;
    return text ? (JSON.parse(text) as ScreenContext) : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Example read tool. Replace the body with a real lookup against your system.
// Keep the name a read (search_/get_/list_) and keep readOnlyHint true.
// ---------------------------------------------------------------------------

server.registerTool(
  "search_items",
  {
    title: "Search items",
    description:
      "Search __NAME__ for items matching a query. Returns up to `limit` results with id, title, and url.",
    inputSchema: {
      query: z.string().describe("Free text query"),
      limit: z.number().int().min(1).max(20).default(5),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ query, limit }) => {
    // Optional: ground the search in what the user is looking at.
    const ctx = await holmesScreenContext();
    const hint = ctx?.windowTitle ? ` (user is viewing: ${ctx.windowTitle})` : "";

    // TODO: replace with a real call.
    const results = Array.from({ length: Math.min(limit, 3) }, (_, i) => ({
      id: `item-${i + 1}`,
      title: `Example result ${i + 1} for "${query}"${hint}`,
      url: `https://example.com/items/${i + 1}`,
    }));

    return { content: [{ type: "text", text: JSON.stringify(results, null, 2) }] };
  }
);

server.registerTool(
  "get_item",
  {
    title: "Get item",
    description: "Fetch one __NAME__ item by id, with its full body.",
    inputSchema: { id: z.string() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ id }) => {
    // TODO: replace with a real call.
    const item = { id, title: `Example item ${id}`, body: "Replace me with real content." };
    return { content: [{ type: "text", text: JSON.stringify(item, null, 2) }] };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
