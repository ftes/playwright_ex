# PlaywrightEx

A statement-by-statement port of the Playwright JS client to Elixir. The rules are in
[`PORTING.md`](PORTING.md) (how to port) and [`docs/architecture.md`](docs/architecture.md) (why).
Read them before changing ported code.

- Deviate only where the port requires it. For an edge case upstream's client shares, keep
  upstream's behaviour, even when it looks wrong, and don't add a special case.
- `mix check` is the full verification (format, credo, compile, dialyzer, parity, tests).
- Files marked "do not edit manually" are generated: run `mix playwright_ex.gen.api`
  (`mix playwright_ex.gen.protocol` for the protocol) instead of editing them.
- No attribution anywhere: no `Co-Authored-By` trailers or "Generated with" lines.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage-rules-end -->
