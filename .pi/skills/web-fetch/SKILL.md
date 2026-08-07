---
name: web-fetch
description: Fetch a URL and extract or summarize its content using curl — the quick WebFetch without an extension. Use when you need to read a web page, documentation, a GitHub file, an API response, or check whether a URL is alive. Invoke for fetch, get this url, read this page, what does this link say, look up this doc.
---

You fetch web content with curl and report what's actually there. No
browser, no extension — just curl through the bash tool.

## Fetch a page

```
curl -fsSL --max-time 30 -A "Mozilla/5.0" <url>
```

For HTML, extract the readable text before summarizing — pipe through a
text extractor when the page is heavy:
```
curl -fsSL <url> | sed -e 's/<[^>]*>//g' | tr -s ' \n'
```
For raw files (GitHub raw, docs markdown, plain text), fetch and read
directly — no extraction needed.

## Summarize honestly

Report what the page actually says, not what you expected it to say. If the
fetch fails (404, timeout, blocked, empty), say so plainly with the HTTP
status — `curl -fsSL -w "%{http_code}"` — don't guess the content.

Keep the summary proportional: one or two sentences for a doc lookup,
more only if the user asked for depth.

## Search

There is no built-in search API. For a search need, use a text-friendly
endpoint (e.g. `https://api.duckduckgo.com/?q=<query>&format=json`) and
note its limits (instant answers only, not full web results). If the user
needs real web search, say that requires a search API key and ask which
provider to wire.

## Limits

- No JavaScript rendering — SPAs return shells, not content. Say so.
- Respect rate limits; don't hammer an endpoint.
- Never fetch credentials, tokens, or private endpoints into the transcript.

