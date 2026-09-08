# Holmes SDK

Holmes is open source, and the point of the SDK is that you can add to it
without forking the app. There are two things you can add, and one helper.

| You want to… | Use | Where |
|---|---|---|
| Make Holmes notice a new situation and prepare something | a **playbook manifest**, one JSON file | [`playbooks/`](playbooks/README.md) |
| Give Holmes a new ability, such as reading your issue tracker or your notes | an **MCP server**, any language | [`mcp/`](mcp/README.md) |
| Scaffold, validate, install, and lint either of the above | the **`holmes-sdk` CLI** | [`bin/holmes-sdk`](bin/holmes-sdk) |

## Two minute start

```sh
# 1. put the CLI on your PATH (it is a single Python 3 script)
ln -s "$PWD/holmes/sdk/bin/holmes-sdk" /usr/local/bin/holmes-sdk

# 2. a new playbook, installed straight into Holmes
holmes-sdk playbook new linear-ticket-summary --install
#    edit ~/Library/Application Support/Holmes/playbooks/linear-ticket-summary.json
#    Holmes reloads the folder as you save

# 3. a new tool server, wired into Holmes
holmes-sdk mcp new mytracker --lang ts
cd mytracker && npm install && npm run build
holmes-sdk mcp add mytracker -- node "$PWD/dist/index.js"
holmes-sdk mcp lint mytracker      # which tools Holmes will actually offer
```

## The rule that shapes everything here

Holmes promises it can only ever draft. It never sends, posts, deletes, or
modifies anything on its own. That promise is enforced in code by a tool
filter and a confirmation gate, and it survives only because nothing you add
through the SDK runs inside the app.

- A playbook manifest is data. Holmes compiles it. It cannot name a tool, a
  backend, or a coordinate, and the draft only rule is appended to its prompt
  by the loader.
- An MCP server is a separate process. Every tool it exposes passes through
  the same default deny filter as the built in integrations. A tool is
  offered only if it declares `readOnlyHint` and its name reads as a read.

There is deliberately no way to load code into Holmes. If you need something
neither surface allows, open an issue and describe the situation. Playbooks
that prove themselves graduate into the app as first party code, which is how
the five built in ones got there.

## Layout

```
sdk/
  README.md                this file
  bin/holmes-sdk           CLI (Python 3, no dependencies)
  playbooks/
    README.md              manifest format
    playbook.schema.json   JSON schema for editor completion
    examples/              working manifests
  mcp/
    README.md              how Holmes discovers, filters, and calls your tools
    template-ts/           TypeScript server template
    template-py/           Python server template
```
