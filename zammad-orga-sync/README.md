# zammad-orga-sync

*English — [deutsche Fassung](README.de.md)*

> ## ⚠️ USE AT YOUR OWN RISK — NO WARRANTY, NO SUPPORT, NO GUARANTEES
>
> **This script writes to your Zammad installation.** It creates organizations
> and changes the primary organization of users, in bulk and without asking for
> confirmation. A wrong field name, a wrong role or an unnoticed typo can
> reassign thousands of users in a single run.
>
> **You alone are responsible for running it.** It comes with **absolutely no
> warranty**, express or implied, and the author accepts **no liability** for
> any damage, data loss or downtime. The binding wording is the MIT licence in
> [LICENSE](../LICENSE).
>
> **This is not an official Zammad product.** It is not part of Zammad, it was
> not built by Zammad GmbH and it is not endorsed by them. Using it is **not
> covered by any Zammad subscription**, maintenance agreement or support
> contract, and Zammad support will not help with problems it causes. If it
> damages your instance, repairing it is your job.
>
> **Before every run against production:**
> have a backup you have actually restored at least once; run it with
> `--dry-run` first and read the plan line by line; start with `--limit` to
> watch the effect on a handful of users.

Creates organizations from a user field and assigns them as the primary
organization. Made to be run from cron or by hand.

Licence: MIT, Copyright (c) 2026 Tobias Siudak, see [LICENSE](../LICENSE).

An example: users are created from another system, and the company name lands
in a free field, say `company`. Zammad does not turn that into an organization
by itself. This script closes the gap.

## At a glance

Five calls, in the order they are meant to be used. Nothing is written before
number three.

```sh
# 1  Does it work at all? Checks access, token and field, looks at 50 users,
#    writes nothing, and projects how long the whole set would take.
./zammad-orga-sync.sh --field company --dry-run

# 2  The complete plan. Read it line by line - this is the moment to catch a
#    wrong field or a company name that belongs on the ignore list.
./zammad-orga-sync.sh --field company --dry-run --no-limit

# 3  Really write twenty, then look at those users in Zammad. This is also the
#    first run that measures how fast this Zammad writes.
./zammad-orga-sync.sh --field company --limit 20

# 4  A larger measured batch. The more it writes, the better the projection.
./zammad-orga-sync.sh --field company --limit 200

# 5  The whole run.
./zammad-orga-sync.sh --field company
```

Steps 1 and 2 change nothing, so there is no reason to skip them. Steps 3 and 4
exist because a projection made from twenty real writes on your own machine is
worth more than any number in this file.

## How long will it take

Every run ends with what it cost and what that means for a bigger one:

```
Timing: 200 user(s) in 54 s - 0.4 s once, 54 s for these users and 400 change(s)
Projection, reading and writing together - rough, and better the more this run did:
    100 user(s)                  27 s
    1000 user(s)                 4 min 29 s
    10000 user(s)                44 min 42 s
    1780 user(s) still in scope  7 min 58 s
```

A run has two kinds of cost, and the script keeps them apart. Some of it is
paid once however big the job is: starting Rails, asking for the counts,
fetching the organizations. The rest grows with the number of users. Only the
second kind is multiplied - otherwise a sample of fifty would scale a single
eight-second Rails start into an hour that never happens.

A dry run writes nothing, so it can only project reading and deciding, and it
says so. The write rate comes from the first real run, which is what steps 3
and 4 above are for.

**A dry run without `--limit` looks at 50 users**, so the first call of a
session stays quick even on a large installation. `--limit N` widens the
sample, `--no-limit` drops it. A real run without `--limit` still processes
everything, as before.

## The two access modes

| Mode | Where the script runs | How it reaches Zammad |
|---|---|---|
| `local` (default) | on the Zammad host | through the Rails console, `zammad run` |
| `api` | anywhere | through the REST API, also against a remote host |

The local mode needs `root` or the `zammad` user and is faster because it goes
straight to the database. The API mode needs a URL and a token:

```sh
export ZAMMAD_TOKEN=...
./zammad-orga-sync.sh --access api --url https://zammad.example.com --field company
```

**Token permissions:** `admin.user` and `admin.organization`. Only when
`--role` is used does `admin.role` have to be added.

**Self-signed certificates.** If this machine cannot validate the certificate
of the Zammad server, typically a self-signed one or one from an internal
certificate authority, the run stops with *The TLS certificate was rejected*.
`--no-ssl-verify` (equivalently `--insecure` or `-k`) gets past that.

It is **less secure**: the connection stays encrypted, but nothing proves that
your Zammad is what answers at the other end. Anyone able to reroute the
traffic can read and change it, and your API token ends up with them. You know
this from `curl -k`. While verification is off, the script prints a warning to
stderr on every run, `--quiet` included.

The better fix is to put the internal CA certificate into the machine's trust
store: on Debian and Ubuntu into `/usr/local/share/ca-certificates/` followed
by `update-ca-certificates`, on RHEL and SUSE into
`/etc/pki/ca-trust/source/anchors/` followed by `update-ca-trust`. After that
verification simply works and the option becomes unnecessary.

The token belongs in the environment, not in the file. A value set there wins
over the one written in the settings block of the script.

## The four operating cases

They follow from two switches; there is nothing to select separately.

| Case | Invocation | Which users | What happens |
|---|---|---|---|
| 1 default | `--field company` | no primary organization, field filled | create the organization if needed, assign it |
| 2 overwrite | `+ --overwrite` | every user with a filled field | like 1, and a differing existing organization is replaced |
| 3 role | `+ --role Customer` | like 1, restricted to the roles | like 1 |
| 4 role and overwrite | `+ both` | like 2, restricted to the roles | like 2 |

`--role` and `--blacklist` are repeatable. When overwriting and the existing
organization already matches the field, nothing changes; the field only wins on
a real difference.

## Creating organizations, or not

By default an organization that does not exist yet is created. `--no-create-orgs`
turns that off: the script then only assigns organizations that are already
there, and leaves every other user untouched.

That is the mode for an instance where the organizations are maintained by hand
or come from another system, and the user field is only meant to point at them.

Skipped users are not swallowed. Each one is named:

```
Skipped: 6 (organization does not exist, --no-create-orgs)

  skipped Anna Fehlt <anna@example.com>: no organization named 'Fehlt eins GmbH'
  ...

Result: 0 organization(s) created, 4 user(s) assigned, 6 skipped for want of an organization, 0 error(s)
```

The count is in the summary line, which is printed even with `--quiet`, and the
individual lines go into the log. A repeat run says *Nothing to do: 6 user(s)
skipped for want of an organization* rather than a bare *Nothing to do*, so a
nightly job does not look idle while it is in fact stuck on missing
organizations.

`--shared` has no effect in this mode: it only ever applied to organizations the
script creates itself.

## Settings

Everything sits in a block at the top of the script and can additionally be
given on the command line.

| Setting | Option | Default |
|---|---|---|
| Access mode | `--access` | `local` |
| URL | `--url` | empty |
| Token | `--token`, better `ZAMMAD_TOKEN` | empty |
| Certificate check | `--no-ssl-verify` turns it off | on |
| Field name | `--field` | `company` |
| Ignore list | `--blacklist` | private, -, n/a, unknown |
| Roles | `--role` | empty, meaning all |
| Overwrite | `--overwrite` | off |
| Create missing organizations | `--no-create-orgs` turns it off | on |
| New organizations shared | `--shared` | off |
| Dry run | `--dry-run` | off |
| Sample size | `--limit N`, `--no-limit` | 50 in a dry run, all in a real run |
| Summary only | `--quiet`, also `--silent` | off |
| Log directory | `--log-dir`, `--no-log` | `log` next to the script |
| Log retention | `--log-keep-days` | 30 days |

## The log is made to be parsed

Every line that touches a record is written with the same fixed fields:

```
2026-09-28 22:18:22 | unlink-secondary | Eva Zweit <eva@example.com> | Alpha AG | was a secondary organization
2026-09-28 22:18:22 | change           | Eva Zweit <eva@example.com> | Alpha AG | was Beta AG
2026-09-28 22:18:20 | create-orga      |                             | Gamma GmbH | id 10626, not shared
```

```
timestamp | action | user | organization | detail
```

The timestamp is the moment of the write, the action is one word, and the
fields are separated by ` | `. So a log can be taken apart afterwards without
reading prose:

```sh
grep ' | create-orga | ' log/zammad-orga-sync-*.log          # every organization created
grep -c ' | change | '   log/zammad-orga-sync-*.log          # how many were moved
cut -d'|' -f3 log/*.log | sort -u                            # every user touched
```

| action | what it did |
|---|---|
| `create-orga` | an organization was created |
| `assign` | primary organization set, the user had none |
| `change` | primary organization replaced by a different one |
| `unlink-secondary` | the organization was taken out of the user's secondary list so it could become the primary one |
| `skip-no-orga` | user left alone: the organization is missing and `--no-create-orgs` forbids creating it |
| `error-orga` | creating an organization failed |
| `error-user` | writing a user failed |
| `plan-*` | the same in a dry run, where nothing was written |

A pipe inside an organization name would make that one line ambiguous. The
script does not escape it, because escaping would be harder to read than that
case is likely.

The lines follow `--quiet` like every other per-record output; only the
failures and the summary are printed regardless. The summary line and the
timing block stay prose - they are meant for a person.

## How a user appears in the output

Every line that names a user - planned, written, skipped or failed - uses the
first name, the last name and the e-mail address, because that is what an
administrator recognises in Zammad:

```
  Max Mustermann <max@example.com>: ACME Ltd
  Erika Musterfrau: ACME Ltd
  nurmail@example.com: ACME Ltd
```

A user without an e-mail address is shown by name alone, one without a name by
the address alone. Only a record that carries neither falls back to the login,
so that it can still be found.

## How names are compared

Before comparing, the field value is trimmed at the edges and runs of inner
whitespace are collapsed into one. The comparison ignores case, because Zammad
checks the uniqueness of organization names the same way.

So `"  ACME   Ltd  "` becomes the organization `ACME Ltd`, and an existing
`acme ltd` counts as the same one. Creation uses the cleaned-up spelling from
the field.

If twenty users need the same new organization, it is created once.

## What the script does not do

- It creates **no** users and deletes nothing.
- It leaves **secondary** organizations alone, with one exception: if an
  organization is to become primary while it is listed as a secondary one on
  the same user, it is removed from there. Zammad forbids both at once.
- It does not change **existing** organizations, not even their "shared" flag.
  `--shared` applies to newly created ones only, and with `--no-create-orgs`
  it applies to nothing at all.
- Without `--overwrite` it does not touch users that already have an
  organization.

## Logging

Every real run writes its complete output to a log file, in addition to the
console. By default the file lands in a `log` folder next to the script, which
is created on first use:

```
log/zammad-orga-sync-20260924-194147.log
```

**The log path is checked before any work starts, by actually writing to it.**
Permission bits say nothing about a full disk, a read-only mount, a quota or
SELinux; only a real write does. If that write fails, the run is refused and
nothing is changed. The reason always reaches the console, `--quiet` and
`--silent` included, because a silent job that quietly refuses to work is worse
than a noisy one.

A dry run writes no file, but the path is still tested, so a broken log
directory surfaces while you are trying things out rather than in the middle of
the night.

| Option | Meaning | Default |
|---|---|---|
| `--log-dir PATH` | where to write | `log` next to the script |
| `--log-keep-days N` | delete own logs older than N days, 0 keeps all | 30 |
| `--no-log` | write no log at all | logging is on |

Cleanup only ever removes files named `zammad-orga-sync-*.log` in that
directory, so a shared log path stays safe.

The API token is never written to the log.

If you install the script into a system directory you cannot write to, point
the logs elsewhere, for example `--log-dir /var/log/zammad-orga-sync`.

## Repeatability

A second run with the same settings finds nothing left to do, which makes the
script suitable for cron, for example nightly:

```cron
30 2 * * * /usr/local/sbin/zammad-orga-sync.sh --field company --quiet >> /var/log/zammad-orga-sync.log 2>&1
```

Exit status 0 if everything ran, 1 on errors during processing, 2 on a
configuration problem. Individual errors do not abort the run; they are counted
and reported at the end.

In the local mode the changes appear in the Zammad history as changes by the
system user, as with Zammad's own background jobs. In the API mode they appear
under the user the token belongs to.

**A repeat run costs almost nothing.** Both modes ask Zammad to do the
filtering rather than sifting through the users themselves. The local mode
always did: "field filled and no organization" is a `WHERE` clause, and once
everybody has an organization it matches no rows.

Since 2.1 the API mode does the same. It first asks how many users match, with
`/api/v1/users/search` and a condition on `organization_id`, which is one cheap
request. If the answer is none - the normal outcome of a nightly run - it
fetches no users at all. Measured against 10 000 users: **0,5 s instead of 21 s**.

Two details make that safe. The request carries no `query` parameter, so Zammad
answers it from the database instead of from Elasticsearch; a stale search index
can therefore never cause a user to be skipped. And if the server will not take
the condition - an older Zammad, a token without the permission, a field that
does not exist - the script quietly falls back to reading the full list, which
is what it did before.

The filter is only used when it saves work. A request costs about the same
whatever it carries, so fetching 9 000 of 10 000 users page by page through the
capped search endpoint would be slower than taking the plain list. The script
compares the two counts and takes the plain list unless the filter removes at
least half the users. On the very first run against a fresh field that is always
the case, so a first run is no slower than before.

## Requirements

Bash and **jq**; the API mode additionally needs **curl**. That is all. No Ruby
has to be installed anywhere.

| System | Command |
|---|---|
| Debian, Ubuntu, Mint | `apt install jq curl` |
| RHEL, Alma, Rocky, Fedora | `dnf install jq curl` (`yum` on RHEL 7) |
| SLES, openSUSE | `zypper install jq curl` |
| Alpine, container images | `apk add bash jq curl` |
| Arch | `pacman -S jq curl` |

On Debian 13 jq pulls 3 packages and about 1 MB; curl is normally already
installed. For comparison, a Ruby installation would pull 19 packages and
45 MB, including web fonts and jQuery.

**Why it is built this way.** The decision logic lives in a single jq program,
so both access modes decide identically. Around it sit two thin input/output
layers: curl for the API, and two short Ruby snippets for the local mode. Those
snippets run through `zammad run` and therefore use the Ruby that Zammad
already ships, which is why nothing has to be installed on the Zammad host
beyond jq.

On a source installation without the `zammad` command, or for a Zammad running
in a container, set `RAILS_CMD` in the settings block:

```sh
# source installation
RAILS_CMD="su - zammad -c 'cd /opt/zammad && bundle exec rails r %s'"
# Zammad in a container
RAILS_CMD="docker exec -i zammad-railsserver-1 rails r %s"
```

## Verified against

As of 2026-09-28, version 2.5.0 (jq core), both access modes, all four
operating cases:

- **Zammad 7.2.0** on Debian 13: ten test users covering every
  edge case, removed completely afterwards
- **Zammad 6.5.4** on Ubuntu 24.04: read-only dry run over 1134
  users, two pages of API pagination, 15 seconds
- **In a container**: the script itself running in `debian:13-slim` and in
  `alpine:3.22`, reaching a Zammad outside the container over the API. A dry
  run over all 1134 users, both pages of pagination, finished in 3 seconds and
  produced the identical plan from both images

The API mode was verified as a genuine remote access: script on one server,
Zammad on the other, across two major versions. Local and API mode produced the
same result line for line.

Edge cases covered: duplicate company names collapse into one organization,
whitespace is cleaned up, the ignore list takes effect, an empty field is
skipped, an already matching assignment stays untouched, the role filter keeps
other roles out, and turning a secondary organization into the primary one
passes Zammad's validation.

Certificate handling was verified against a self-signed HTTPS endpoint: the
default run stops with a clear message, `--no-ssl-verify` proceeds and warns,
and the warning survives `--quiet`.

The record lines of 2.5 were verified in both access modes against a set that
triggers every action: an organization created and assigned, two users sharing
a new one, a primary organization replaced, and one where the wanted
organization sat in the user's secondary list and had to be taken out first.

That last case found a real defect during the work, now fixed: a user **without**
a primary organization but **with** the wanted one among the secondary ones is
the ordinary first case, and Zammad refuses the write with *Secondary
organizations cannot include the primary organization* unless the entry is
removed. Both access modes now decide that from the same plan.

The output of 2.4 names users by first name, last name and e-mail. Verified in
both access modes against records of every shape: name with address, name
without, address without name, neither of the two (falls back to the login) and
a name with umlauts and a hyphen.

`--no-create-orgs` (2.3) was verified in both access modes against a set of ten
users, four of whose organizations existed - including one in a different case
and one with stray whitespace, both of which still matched - and six whose did
not. Four were assigned, six were skipped and named one by one, no organization
was created, and the repeat run reported them again instead of claiming there
was nothing to do.

The sampling and projection of 2.2 were verified against Zammad 7.2 with 2 000
users, in both access modes: a dry run without --limit fetches 50 users and
finishes in under a second, --no-limit walks all 2 000, and the projection for
10 000 users tightened from 1 h 10 min to 45 min as the measured batch grew
from 20 to 200 real writes. In the local mode the two Rails starts (17 s) are
reported as a one-off cost and are correctly not multiplied.

The server-side filter of 2.1 was verified against Zammad 7.2 with 10 000
users: the filtered and the unfiltered path produce the identical plan, an
unknown field still reports *This Zammad has no user field called ...* because
Zammad rejects the condition and the script falls back, and `--overwrite` skips
the filter as intended. A repeat run over those 10 000 users dropped from 21 s
to 0,5 s.

One defect was found this way and fixed in 2.0.1: the API mode used to hand
the collected lists to jq as command line arguments, and Linux caps a single
argument at 128 KiB, which is roughly sixty users. Anything larger died with
*Argument list too long*. The lists now travel through files.

Logging was verified too: a real run contains the complete output between
header and footer, an unwritable log directory refuses the run with exit
status 2 and says why even under `--silent`, and cleanup with
`--log-keep-days 20` deleted only its own 40-day-old file while leaving a
5-day-old one and an unrelated `fremd.log` in the same directory alone.

## Known limits

- The field has to be a text field on the user object. Select fields with
  key-value pairs deliver the key, not the label.
- Very large installations load all users and organizations into memory. With
  tens of thousands of users that is noticeable but bearable; the script is
  meant for one run per night.
- It does not detect renames. If a company is spelled differently in the field,
  a second organization appears, unless the difference is only case or
  whitespace.
