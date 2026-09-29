# zammad-tools

Small command-line tools for administering [Zammad](https://zammad.org).

> **Use at your own risk.** These tools are not official Zammad products, are
> not endorsed by Zammad GmbH and are not covered by any Zammad subscription
> or support contract. Some of them write to your installation or put heavy
> load on it. Read the notes in each tool before running it, and keep a
> backup you have restored at least once.

## Tools

| Tool | Language | What it does |
|------|----------|--------------|
| [zammad-orga-sync](zammad-orga-sync/) | Bash | Creates organizations from a user field and assigns them as the users' primary organization. Runs via `rails runner` or the REST API, with dry run, limits and an evaluable log. Documentation in English and German. |
| [ticket_overview_counter.rb](ticket_overview_counter.rb) | Ruby | Counts the tickets in every overview as seen by every agent and shows the top 3, to judge which overviews cause server load. Run with `zammad run rails r ticket_overview_counter.rb`. |
| [zammad_ticket_history_count.sh](zammad_ticket_history_count.sh) | Bash | Reads ticket counts per group and state from the Zammad API and exports them with timestamps to Elasticsearch for historical analysis. |

Requirements and usage are described in the header of each script or, for
`zammad-orga-sync`, in its README.

## Issues

Bug reports and suggestions are welcome as
[GitHub issues](https://github.com/byPARSE/zammad-tools/issues).

## Licence

MIT, Copyright (c) 2025-2026 Tobias Siudak. See [LICENSE](LICENSE).
