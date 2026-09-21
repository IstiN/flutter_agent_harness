# Fa Blog — content pipeline

Canonical content for the [fa1.dev blog](https://fa1.dev/blog/) lives here, in
plain Markdown, so the same text can be reused for LinkedIn, X, Telegram, and
anywhere else.

## Layout

```
blog/
  posts/    — canonical long-form articles (published to fa1.dev/blog/)
  social/   — per-network adaptations (LinkedIn posts, X threads, …)
```

## Post format

One file per post in `posts/`, named `<YYYY-MM-DD>-<slug>.md`, with YAML
frontmatter:

```markdown
---
title: My AI agent took 38 seconds to remember its own name
date: 2026-09-19
description: One-paragraph teaser used for the index page and og:description.
tags: [fa, agents, dogfooding]
author: Uladzimir Klyshevich
video: https://...   # optional: yoclip render URL, embedded under the title
---

Article body in Markdown. Code blocks, tables, and Mermaid-free diagrams
render fine. Keep images in `site/blog/img/` and reference them relatively.
```

Rules:

- English for `posts/` (the site audience); social adaptations may differ.
- Numbers over adjectives. If a bug is in the story, link the commit/issue.
- The same frontmatter block survives copy-paste into LinkedIn articles —
  editors ignore it, humans don't mind.

## Social adaptations

`social/<date>-<slug>.<network>.md` — e.g.
`social/2026-09-19-the-38-second-memory.linkedin.md`. These are NOT published
to the site; they are copy-paste sources. Keep the canonical URL of the blog
post in the CTA line.

## Publishing to fa1.dev

```
dart run scripts/build_blog.dart
```

The script (pure Dart, no deps):

1. reads `blog/posts/*.md` + frontmatter,
2. copies them to `site/blog/posts/`,
3. regenerates `site/blog/posts.json` (the index manifest).

The site itself is static: `site/blog/index.html` lists `posts.json`,
`site/blog/post.html?p=<slug>` renders the Markdown client-side. Commit both
`blog/` and the generated `site/blog/` output — GitHub Pages serves what is
in the repo.
