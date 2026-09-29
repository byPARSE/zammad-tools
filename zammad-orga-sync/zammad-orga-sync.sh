#!/usr/bin/env bash
#
# zammad-orga-sync — create organizations from a user field and assign them.
#
# Copyright (c) 2026 Tobias Siudak
# SPDX-License-Identifier: MIT
# The full licence text is in the LICENSE file at the repository root and is
# repeated at the bottom of this header.
#
# ##########################################################################
# ##                                                                      ##
# ##   USE AT YOUR OWN RISK — NO WARRANTY, NO SUPPORT, NO GUARANTEES      ##
# ##                                                                      ##
# ##########################################################################
#
#   THIS SCRIPT WRITES TO YOUR ZAMMAD INSTALLATION. It creates organizations
#   and changes the primary organization of users, in bulk and without asking
#   for confirmation. A wrong field name, a wrong role or an unnoticed typo
#   can reassign thousands of users in a single run.
#
#   YOU ALONE ARE RESPONSIBLE for running it. It comes with ABSOLUTELY NO
#   WARRANTY, express or implied, and the author accepts NO LIABILITY for any
#   damage, data loss, downtime or any other consequence of its use. See the
#   MIT licence text for the binding wording.
#
#   THIS IS NOT AN OFFICIAL ZAMMAD PRODUCT. It is not part of Zammad, it was
#   not built by Zammad GmbH and it is not endorsed by them. Using it is NOT
#   COVERED BY ANY ZAMMAD SUBSCRIPTION, maintenance agreement or support
#   contract, and Zammad support will not help with problems it causes. If it
#   damages your instance, repairing it is your job.
#
#   BEFORE EVERY RUN AGAINST PRODUCTION:
#     * have a backup that you have actually restored at least once
#     * run it with --dry-run first and read the plan line by line
#     * start with --limit to watch the effect on a handful of users
#
# ##########################################################################
#
# For every user the script reads a field of your choice (for example
# "company"), looks up the organization named there, creates it if it does not
# exist yet and sets it as the user's primary organization. Meant to be run
# from cron or by hand.
#
# Two ways to reach Zammad:
#   local  — on the Zammad host itself, through the Rails console
#   api    — through the REST API, also against a remote host or a container
#
# Usage:
#   ./zammad-orga-sync.sh [options]
#   ./zammad-orga-sync.sh --dry-run        show what would happen, change nothing
#   ./zammad-orga-sync.sh --help           full list of options
#
# Requirements: bash and jq; the API mode additionally needs curl. That is all.
# No Ruby has to be installed anywhere: the local mode borrows the Ruby that
# Zammad already ships.
#
#   Debian, Ubuntu, Mint          apt install jq curl
#   RHEL, Alma, Rocky, Fedora     dnf install jq curl      (yum on RHEL 7)
#   SLES, openSUSE                zypper install jq curl
#   Alpine, container images      apk add bash jq curl
#   Arch                          pacman -S jq curl
#
# ─────────────────────────────────────────────────────────────────────────────
# MIT License
#
# Copyright (c) 2026 Tobias Siudak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ─────────────────────────────────────────────────────────────────────────────
#
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Settings. Every one of them can also be given on the command line, see --help.
# ─────────────────────────────────────────────────────────────────────────────

# Access mode: "local" (on the Zammad host) or "api" (through REST).
ACCESS="local"

# For ACCESS="api" only: base URL without a trailing slash and a token holding
# the permissions admin.user and admin.organization.
#
# Both can also come from the environment, and a value set there wins over the
# one written here. For the token that is the recommended way, because it then
# lives in no file at all:
#   export ZAMMAD_TOKEN=...
ZAMMAD_URL="${ZAMMAD_URL:-}"
ZAMMAD_TOKEN="${ZAMMAD_TOKEN:-}"

# Verify the TLS certificate of the Zammad server? Default: yes, and it should
# stay that way.
#
# Set this to "false" (or pass --no-ssl-verify) only when Zammad uses a
# certificate this machine cannot validate, typically a self-signed one or one
# from an internal certificate authority. Turning verification off means the
# connection is still encrypted, but nothing proves you are talking to the
# right server: anyone able to reroute the traffic can read and change it, and
# your API token travels straight into their hands.
#
# The better fix is to install the internal CA certificate on this machine, for
# example into /usr/local/share/ca-certificates/ followed by update-ca-certificates
# on Debian and Ubuntu, or /etc/pki/ca-trust/source/anchors/ followed by
# update-ca-trust on RHEL and SUSE. Then verification simply works.
SSL_VERIFY="true"

# Name of the user field that holds the organization name.
FIELD="company"

# Organization names to ignore. Case does not matter.
BLACKLIST=(
  "private"
  "-"
  "n/a"
  "unknown"
)

# Restrict the run to these roles. Empty means every user.
# Example: ROLES=("Customer" "Agent")
ROLES=()

# Replace an existing primary organization? Default: no.
CREATE_ORGS="true"    # create an organization that does not exist yet
OVERWRITE="false"

# Mark newly created organizations as shared? Default: no.
SHARED="false"

# Only report, change nothing.
DRY_RUN="false"

# Directory for log files. The default is a "log" folder next to this script,
# created on first use. Set it to "" (or pass --no-log) to switch logging off.
#
# On a real run the complete output is written to
# <LOG_DIR>/zammad-orga-sync-YYYYMMDD-HHMMSS.log in addition to the console.
# A dry run writes no file, but the directory is still tested, so that a broken
# log path shows up while you are trying things out and not in the middle of
# the night.
#
# The path is checked before anything else happens, by actually writing to it.
# If that fails the run is refused. There is nothing more annoying than a job
# that does all the work and then cannot write down what it did.
#
# If you install the script into a system directory you cannot write to, point
# this somewhere else, for example LOG_DIR="/var/log/zammad-orga-sync".
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LOG_DIR="${SCRIPT_DIR:-.}/log"

# Delete log files older than this many days. 0 keeps them forever.
# Only files named zammad-orga-sync-*.log in LOG_DIR are ever removed.
LOG_KEEP_DAYS=30

# How to invoke Rails for the local access mode. The default fits package
# installations. Two other shapes that come up:
#   source install:      RAILS_CMD="su - zammad -c 'cd /opt/zammad && bundle exec rails r %s'"
#   Zammad in a container: RAILS_CMD="docker exec -i NAME rails r %s"
# The %s is replaced by the arguments of the Ruby snippet.
RAILS_CMD=""

# ─────────────────────────────────────────────────────────────────────────────
# No changes needed below this line.
# ─────────────────────────────────────────────────────────────────────────────

VERSION="2.5.0"
PROGRAM="$(basename "$0")"
LIMIT=0
LIMIT_GIVEN="false"   # did the caller say anything about the size of the run?
QUIET="false"
PAGE_SIZE=1000        # upper bound of Zammad's own pagination
SEARCH_PAGE_SIZE=200  # the /search endpoint is capped lower than the plain list
SEARCH_MAX=2000       # ten filtered pages; beyond that the plain list wins
DRY_SAMPLE=50         # how many users a dry run looks at when nothing is asked

usage() {
  cat <<TEXT
$PROGRAM $VERSION — create organizations from a user field and assign them

  --access local|api       Access mode (currently: $ACCESS)
  --url ADDRESS            Zammad base URL for the API, e.g. https://zammad.example.com
  --token TOKEN            API token; better supplied as ZAMMAD_TOKEN in the environment
  --no-ssl-verify          Do not verify the server certificate (also: --insecure).
                           Less secure, see the note at the end of this help.
  --field NAME             User field holding the organization name (currently: $FIELD)
  --role NAME              Only users holding this role; repeatable
  --blacklist NAME         Ignore this organization name; repeatable
  --overwrite              Replace an existing primary organization
  --shared                 Create new organizations as shared
  --no-create-orgs         Never create an organization. Users whose
                           organization does not exist yet are skipped,
                           listed and counted
  --dry-run                Only report, change nothing. On its own it looks at
                           $DRY_SAMPLE users and projects the time from that
  --limit N                Look at at most N users in scope
  --no-limit               Look at all of them, also in a dry run
  --log-dir PATH           Write the log there (currently: ${LOG_DIR:-off})
  --log-keep-days N        Delete own log files older than N days, 0 keeps all
                           (currently: $LOG_KEEP_DAYS)
  --no-log                 Do not write a log file at all
  --quiet                  Print the summary only (also: --silent)
  --version                Print the version
  --help                   This help

Five calls, in the order they are meant to be used:

  1  ./$PROGRAM --field company --dry-run
     Does it work at all? Checks the access, the token and the field, looks at
     $DRY_SAMPLE users, writes nothing, and projects how long the whole set takes.

  2  ./$PROGRAM --field company --dry-run --no-limit
     The complete plan. Read it line by line - this is the moment to catch a
     wrong field or a company name that should be on the ignore list.

  3  ./$PROGRAM --field company --limit 20
     Really write twenty, then look at those users in Zammad. This is also the
     first run that measures how fast this Zammad writes.

  4  ./$PROGRAM --field company --limit 200
     A larger measured batch. The more it writes, the better the projection for
     what is left.

  5  ./$PROGRAM --field company
     The whole run.

The four operating cases follow from --role and --overwrite:

  neither                  users without a primary organization and a filled field
  --overwrite only         every user with a filled field, the field wins
  --role only              like the first case, restricted to the given roles
  --role and --overwrite   like the second case, restricted to the given roles

Needs bash and jq; the API mode also needs curl. Nothing else, and no Ruby
installation: the local mode borrows the Ruby that Zammad already ships.

  Debian, Ubuntu, Mint        apt install jq curl
  RHEL, Alma, Rocky, Fedora   dnf install jq curl
  SLES, openSUSE              zypper install jq curl
  Alpine, container images    apk add bash jq curl
  Arch                        pacman -S jq curl

Exit status: 0 if everything ran, 1 on errors while processing, 2 on a
configuration problem.

About --no-ssl-verify: the connection stays encrypted, but nothing proves you
are talking to the right server, and your API token goes to whoever answers.
Use it only on a trusted network against a host with a self-signed or internal
certificate. The better fix is to install the internal CA certificate on this
machine so that verification just works.

USE AT YOUR OWN RISK. This script changes user and organization records in
bulk, without asking. No warranty, no liability, not an official Zammad
product and not covered by any Zammad support contract. Always try --dry-run
first and keep a backup you have restored once. MIT licensed, see LICENSE.
TEXT
}

die() { printf '\nERROR: %s\n\n' "$*" >&2; exit 2; }
say() { [ "$QUIET" = "true" ] || printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --access)     ACCESS="${2:-}"; shift 2 ;;
    --url)        ZAMMAD_URL="${2:-}"; shift 2 ;;
    --token)      ZAMMAD_TOKEN="${2:-}"; shift 2 ;;
    --no-ssl-verify|--insecure|-k) SSL_VERIFY="false"; shift ;;
    --field)      FIELD="${2:-}"; shift 2 ;;
    --role)       ROLES+=("${2:-}"); shift 2 ;;
    --blacklist)  BLACKLIST+=("${2:-}"); shift 2 ;;
    --overwrite)  OVERWRITE="true"; shift ;;
    --shared)     SHARED="true"; shift ;;
    --no-create-orgs) CREATE_ORGS="false"; shift ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    --limit)      LIMIT="${2:-0}"; LIMIT_GIVEN="true"; shift 2 ;;
    --no-limit)   LIMIT=0; LIMIT_GIVEN="true"; shift ;;
    --log-dir)    LOG_DIR="${2:-}"; shift 2 ;;
    --log-keep-days) LOG_KEEP_DAYS="${2:-0}"; shift 2 ;;
    --no-log)     LOG_DIR=""; shift ;;
    --quiet|--silent) QUIET="true"; shift ;;
    --version)    echo "$PROGRAM $VERSION"; exit 0 ;;
    --help|-h)    usage; exit 0 ;;
    *)            die "Unknown option: $1 (--help lists them all)" ;;
  esac
done

# ── Checks ───────────────────────────────────────────────────────────────────

[ -n "$FIELD" ] || die "No field name given (--field)."
case "$ACCESS" in
  local|api) ;;
  *) die "--access must be 'local' or 'api', not '$ACCESS'." ;;
esac
case "$LOG_KEEP_DAYS" in
  ''|*[!0-9]*) die "--log-keep-days needs a whole number, not '$LOG_KEEP_DAYS'." ;;
esac
case "$LIMIT" in
  ''|*[!0-9]*) die "--limit needs a whole number, not '$LIMIT'." ;;
esac

# A dry run that was not told how much to look at takes a sample and projects
# the rest from it, so the first call of a session stays quick even on a large
# installation. --limit N widens the sample, --no-limit drops it.
LIMIT_IMPLICIT="false"
if [ "$DRY_RUN" = "true" ] && [ "$LIMIT_GIVEN" = "false" ]; then
  LIMIT="$DRY_SAMPLE"
  LIMIT_IMPLICIT="true"
fi

# How many users are in scope altogether, as far as the run can tell. Used for
# the projection, empty when the server could not be asked.
TOTAL_IN_SCOPE=""

# Time spent on work that grows with the number of users, kept apart from the
# fixed cost of a run (starting Rails, the counting requests, fetching the
# organizations). Only the first may be multiplied in a projection.
FETCH_MS=0
WRITE_MS=0

command -v jq >/dev/null 2>&1 || die "jq is missing. It carries the decision logic.
  It is a small package, about 1 MB on Debian 13:

    Debian, Ubuntu, Mint        apt install jq
    RHEL, Alma, Rocky, Fedora   dnf install jq
    SLES, openSUSE              zypper install jq
    Alpine, container images    apk add jq
    Arch                        pacman -S jq"

if [ "$ACCESS" = "api" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is missing, the API mode needs it.

    Debian, Ubuntu, Mint        apt install curl
    RHEL, Alma, Rocky, Fedora   dnf install curl
    SLES, openSUSE              zypper install curl
    Alpine, container images    apk add curl
    Arch                        pacman -S curl"
fi

if [ "$ACCESS" = "api" ]; then
  [ -n "$ZAMMAD_URL" ]   || die "--url is missing (e.g. https://zammad.example.com)."
  [ -n "$ZAMMAD_TOKEN" ] || die "No token. Either --token, or better:
  export ZAMMAD_TOKEN=... and then $PROGRAM --access api --url ..."
  ZAMMAD_URL="${ZAMMAD_URL%/}"
  case "$ZAMMAD_URL" in
    https://*) ;;
    *) [ "$SSL_VERIFY" = "false" ] && printf 'Note: --no-ssl-verify has no effect, the URL is not https.\n' >&2 ;;
  esac
else
  [ "$SSL_VERIFY" = "false" ] \
    && printf 'Note: --no-ssl-verify has no effect in the local access mode.\n' >&2
  if [ -z "$RAILS_CMD" ]; then
    command -v zammad >/dev/null 2>&1 \
      || die "The 'zammad' command is missing. For a source installation or a
  Zammad running in a container, set RAILS_CMD at the top of this script; two
  ready-made shapes sit there as comments."
    RAILS_CMD="zammad run rails r %s"
    [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "zammad" ] \
      || die "The local access mode needs root or the zammad user."
  fi
fi

# ── Logging ──────────────────────────────────────────────────────────────────
#
# The log path is proven by writing to it, not by asking the file system
# whether it looks writable. Permission bits say nothing about a full disk, a
# read-only mount, a quota or SELinux; only a real write does. This happens
# before any work starts, so the run either logs or does not begin. The refusal
# always reaches the console, --quiet and --silent included, because a silent
# job that refuses to work is worse than a noisy one.

LOG_FILE=""

check_log_dir() {
  local probe
  mkdir -p -- "$LOG_DIR" 2>/dev/null \
    || die "Log directory '$LOG_DIR' does not exist and cannot be created.
  Create it by hand, point elsewhere with --log-dir, or switch logging off
  with --no-log."

  probe="$LOG_DIR/.write-test-$$"
  if ! (: > "$probe") 2>/dev/null; then
    rm -f -- "$probe" 2>/dev/null
    die "Cannot write into the log directory '$LOG_DIR'.
  Running as $(id -un). Check the permissions, the free space and whether the
  file system is mounted read-only. Or use --log-dir / --no-log."
  fi
  rm -f -- "$probe" 2>/dev/null
}

# Removes only this script's own log files, never anything else in the
# directory, so a shared log path stays safe.
rotate_logs() {
  local removed
  [ "$LOG_KEEP_DAYS" -gt 0 ] 2>/dev/null || return 0
  command -v find >/dev/null 2>&1 || return 0

  removed="$(find "$LOG_DIR" -maxdepth 1 -type f -name 'zammad-orga-sync-*.log' \
                  -mtime "+$LOG_KEEP_DAYS" -print 2>/dev/null | wc -l)"
  find "$LOG_DIR" -maxdepth 1 -type f -name 'zammad-orga-sync-*.log' \
       -mtime "+$LOG_KEEP_DAYS" -delete 2>/dev/null
  [ "${removed:-0}" -gt 0 ] && say "Removed $removed log file(s) older than $LOG_KEEP_DAYS day(s)."
  return 0
}

if [ -n "$LOG_DIR" ]; then
  check_log_dir
  rotate_logs
  if [ "$DRY_RUN" != "true" ]; then
    LOG_FILE="$LOG_DIR/zammad-orga-sync-$(date +%Y%m%d-%H%M%S).log"
    {
      printf '=== %s %s on %s ===\n' "$PROGRAM" "$VERSION" "$(hostname 2>/dev/null)"
      printf 'started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
      printf 'user:    %s\n' "$(id -un)"
      # The token is deliberately not written here, nor anywhere else in the log.
      printf 'access:  %s%s\n' "$ACCESS" \
             "$([ "$ACCESS" = "api" ] && printf ' (%s)' "$ZAMMAD_URL")"
      printf 'field:   %s\n' "$FIELD"
      printf 'roles:   %s\n' "$([ "${#ROLES[@]}" -gt 0 ] && printf '%s ' "${ROLES[@]}" || printf 'all')"
      printf 'switches: overwrite=%s shared=%s limit=%s ssl_verify=%s\n\n' \
             "$OVERWRITE" "$SHARED" "$LIMIT" "$SSL_VERIFY"
    } >> "$LOG_FILE" 2>/dev/null \
      || die "Cannot write the log file '$LOG_FILE'. Nothing was changed."
  fi
fi

# ── Working directory ────────────────────────────────────────────────────────

TMP="$(mktemp -d)" || die "Cannot create a temporary directory."
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# jq builds every JSON document, so quotes and non-ASCII characters in names
# cannot break anything.
ROLES_JSON="$(printf '%s' "$(jq -n '$ARGS.positional' --args ${ROLES[@]+"${ROLES[@]}"})")"
BLACKLIST_JSON="$(printf '%s' "$(jq -n '$ARGS.positional' --args ${BLACKLIST[@]+"${BLACKLIST[@]}"})")"

ONLY_WITHOUT_ORG="true"
[ "$OVERWRITE" = "true" ] && ONLY_WITHOUT_ORG="false"

jq -n \
  --arg field "$FIELD" \
  --argjson roles "$ROLES_JSON" \
  --argjson only_without_organization "$ONLY_WITHOUT_ORG" \
  --argjson shared "$SHARED" \
  --arg plan_file "$TMP/plan.json" \
  --argjson limit "$LIMIT" \
  '{field: $field, roles: $roles,
    only_without_organization: $only_without_organization, shared: $shared,
    plan_file: $plan_file, limit: $limit}' \
  > "$TMP/config.json"

# In the local mode the Ruby snippets run as the zammad user and must be able
# to read these files. No token is written into them in that mode.
if [ "$ACCESS" = "local" ]; then
  chmod 755 "$TMP"; chmod 644 "$TMP/config.json"
else
  chmod 600 "$TMP/config.json"
fi

# ── The decision, one single implementation ──────────────────────────────────

cat > "$TMP/decide.jq" <<'DECIDE_JQ'
# Turns the collected data into a plan. This is the only place where it is
# decided what happens to whom, so both access modes behave identically.
#
# Input : {users: [...], organizations: [...]} as produced by either backend
# Args  : $blacklist (array of strings), $limit (number),
#         $create_orgs (boolean)
# Output: {scope, skipped, new_orgs, assignments, missing}

# Trim the edges and collapse runs of inner whitespace. "  ACME   Ltd " becomes
# "ACME Ltd", which is also the spelling a new organization is created with.
def clean:
  (. // "") | tostring
  | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
  | gsub("[[:space:]]+"; " ");

# Lowercase for comparison. jq only brings ascii_downcase, so the Latin-1
# supplement is folded by hand; that covers the German umlauts and the accented
# characters of the other Western European languages. Anything outside those
# ranges is compared as written: in the worst case a second organization is
# proposed, and Zammad's own unique index then refuses it with a reported
# error rather than letting something wrong through silently.
def downcase_latin1:
  explode
  | map(
      if   . >= 65  and . <= 90            then . + 32   # A-Z
      elif . >= 192 and . <= 222 and . != 215 then . + 32   # À-Þ without ×
      else . end)
  | implode;

def matchkey: clean | downcase_latin1;

# How a user is named in the output and in the log: first name, last name and
# e-mail address, because that is what an administrator recognises. The login
# is only the last resort for a record that carries neither a name nor an
# address, so that such a user can still be found.
def display:
  ((((.firstname // "") + " " + (.lastname // "")) | clean)) as $name
  | ((.email // "") | clean) as $mail
  | if   $name != "" and $mail != "" then $name + " <" + $mail + ">"
    elif $name != ""                 then $name
    elif $mail != ""                 then $mail
    else (.login // ("user " + (.id | tostring))) end;

. as $data
| ($blacklist | map(matchkey) | map(select(. != ""))) as $blocked
| ($data.organizations | map({key: (.name | matchkey), value: .}) | from_entries) as $orgs
| ($data.users | map(. + {wanted: (.field_value | clean)})) as $all
| (if $limit > 0 then $all[0:$limit] else $all end) as $users
| (reduce $users[] as $u (
      {skipped: {empty_field: 0, blacklisted: 0, already_correct: 0,
                 no_organization: 0}, assignments: []};

      if ($u.wanted == "") then
        .skipped.empty_field += 1

      elif ($blocked | index($u.wanted | matchkey)) then
        .skipped.blacklisted += 1

      # Nothing to do when the assigned organization is already the one named
      # in the field. Only reachable with --overwrite, because otherwise users
      # with an organization are not collected in the first place.
      elif ($u.organization_id != null
            and ($u.organization_name | matchkey) == ($u.wanted | matchkey)) then
        .skipped.already_correct += 1

      else
        .assignments += [{
          user_id: $u.id,
          login: $u.login,
          display: ($u | display),
          organization_name: (($orgs[$u.wanted | matchkey].name) // $u.wanted),
          organization_id: ($orgs[$u.wanted | matchkey].id),
          previous: (if $u.organization_name == null then null else ($u.organization_name | clean) end),
          secondary_ids: ($u.organization_ids // []),
          # Zammad forbids the same organization as primary and secondary at
          # once, so it has to leave the secondary list whenever it is in it.
          # Decided here, so both access modes act and report alike.
          #
          # Do not add "the user already has a primary organization" as a
          # condition: a user without one but with the wanted organization
          # among the secondary ones is the ordinary first case, and the write
          # fails with "Secondary organizations cannot include the primary
          # organization" if the entry is left in place. For a newly created
          # organization the lookup yields null, which is never in the list.
          unlink: (($u.organization_ids // [])
                   | index($orgs[$u.wanted | matchkey].id) != null)
        }]
      end)) as $result

# Users whose organization does not exist yet, and those whose does.
| ($result.assignments | map(select(.organization_id == null))) as $needs_new
| ($result.assignments | map(select(.organization_id != null))) as $ready

# Each missing organization exactly once, even when twenty users need it and
# spell it differently. One spelling wins and becomes the canonical one.
# Without $create_orgs nothing is created, and those users are left alone.
| (if $create_orgs
   then ($needs_new | map(.organization_name) | unique_by(matchkey))
   else [] end) as $new

| ($new | map({key: matchkey, value: .}) | from_entries) as $canonical

| {
    scope: ($users | length),
    skipped: ($result.skipped
              | .no_organization = (if $create_orgs then 0 else ($needs_new | length) end)),
    new_orgs: $new,
    # Every assignment now names the spelling that is actually created,
    # otherwise the apply step would look for an organization nobody made.
    assignments: (if $create_orgs
                  then ($result.assignments
                        | map(if .organization_id == null
                              then .organization_name = $canonical[.organization_name | matchkey]
                              else . end))
                  else $ready end),
    # Reported one by one, so the log says which record was left out and why.
    missing: (if $create_orgs then []
              else ($needs_new | map({display, organization_name})) end)
  }
DECIDE_JQ

# ── Input/output layer: local, through Zammad's own Ruby ─────────────────────

cat > "$TMP/dump.rb" <<'DUMP_RB'
# Collects users and organizations straight from the database and writes them
# as JSON. No decisions are made here.
require 'json'

config = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
field  = config[:field]

# Measured from here, so that starting Rails - several seconds, and paid once
# per run - never ends up in the per-user figure the projection scales.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

out = { field_ok: User.column_names.include?(field),
        known_roles: Role.pluck(:name), users: [], organizations: [] }

if out[:field_ok]
  scope = User.where.not(field => [nil, ''])
  scope = scope.where(organization_id: nil) if config[:only_without_organization]
  if config[:roles].any?
    ids   = Role.where('lower(name) IN (?)', config[:roles].map(&:downcase)).pluck(:id)
    scope = scope.joins(:roles).where(roles: { id: ids }).distinct
  end

  # The total is what the projection extrapolates from, so it is counted even
  # when only a sample is fetched.
  out[:total_in_scope] = scope.count
  scope = scope.limit(config[:limit]) if config[:limit].to_i > 0

  out[:users] = scope.order(:id).map do |u|
    { id: u.id, login: u.login,
      firstname: u.firstname, lastname: u.lastname, email: u.email,
      field_value: u.public_send(field),
      organization_id: u.organization_id, organization_name: u.organization&.name,
      organization_ids: u.organization_ids }
  end
  out[:organizations] = Organization.pluck(:id, :name, :active)
                                    .map { |id, name, active| { id: id, name: name, active: active } }
end

out[:elapsed_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

# The result travels back through standard output between two markers. A file
# would need a directory the zammad user can write to, which is not guaranteed
# for package, source and container installations alike.
puts 'ZOS-JSON-BEGIN'
puts JSON.generate(out)
puts 'ZOS-JSON-END'
DUMP_RB

cat > "$TMP/apply.rb" <<'APPLY_RB'
# Carries out a plan. No decisions are made here either; everything was
# decided by the jq program.
require 'json'

config = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
plan   = JSON.parse(File.read(config[:plan_file]), symbolize_names: true)

# The Rails console has no acting user. Without one every create fails with
# "Created by must exist". As in Zammad's own seeds and migrations the system
# user is set; the changes then appear in the history as system changes.
UserInfo.current_user_id = 1 if defined?(UserInfo)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = { created: [], assigned: [], errors: [] }
by_name = {}

# The same fixed fields the shell writes, so a log reads the same whichever
# access mode produced it. The timestamp is taken when the write happens, even
# though this output only reaches the console once Rails is done.
def zos_record(action, who, orga, detail = '')
  format('%s | %s | %s | %s | %s',
         Time.now.strftime('%Y-%m-%d %H:%M:%S'), action, who, orga, detail)
end

plan[:new_orgs].each do |name|
  organization = Organization.create!(name: name, shared: config[:shared], active: true)
  by_name[name] = organization.id
  result[:created] << { name: name, id: organization.id }
  puts zos_record('create-orga', '', name,
                  "id #{organization.id}, #{config[:shared] ? 'shared' : 'not shared'}")
rescue StandardError => e
  result[:errors] << "creating '#{name}': #{e.message}"
  warn zos_record('error-orga', '', name, e.message)
end

plan[:assignments].each do |a|
  target = a[:organization_id] || by_name[a[:organization_name]]
  if target.nil?
    result[:errors] << "organization '#{a[:organization_name]}' missing for '#{a[:display]}'"
    warn zos_record('error-user', a[:display], a[:organization_name],
                    'organization missing')
    next
  end

  user = User.find(a[:user_id])
  if a[:unlink]
    user.organization_ids = Array(a[:secondary_ids]) - [target]
    puts zos_record('unlink-secondary', a[:display], a[:organization_name],
                    'was a secondary organization')
  end
  user.organization_id = target
  user.save!

  result[:assigned] << { login: a[:login], display: a[:display],
                         organization_name: a[:organization_name] }
  puts zos_record(a[:previous] ? 'change' : 'assign', a[:display],
                  a[:organization_name], a[:previous] ? "was #{a[:previous]}" : '')
rescue StandardError => e
  result[:errors] << "'#{a[:display]}': #{e.message}"
  warn zos_record('error-user', a[:display], a[:organization_name], e.message)
end

result[:elapsed_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

puts 'ZOS-JSON-BEGIN'
puts JSON.generate(result)
puts 'ZOS-JSON-END'
APPLY_RB

chmod 644 "$TMP/dump.rb" "$TMP/apply.rb" 2>/dev/null

# Runs a Ruby snippet through Rails and splits its standard output: the block
# between the markers is written to $2 as JSON, everything else (progress
# lines, Rails warnings) goes to the console as it is.
rails_run() {
  local arguments="$1" target="$2" command raw
  # shellcheck disable=SC2059
  command="$(printf "$RAILS_CMD" "$arguments")"
  raw="$(eval "$command")" || return 1
  printf '%s\n' "$raw" | sed -n '/^ZOS-JSON-BEGIN$/,/^ZOS-JSON-END$/p' | sed '1d;$d' > "$target"
  printf '%s\n' "$raw" | sed '/^ZOS-JSON-BEGIN$/,/^ZOS-JSON-END$/d' | sed '/^[[:space:]]*$/d'
  [ -s "$target" ]
}

# ── Input/output layer: REST API, through curl ───────────────────────────────

CURL_CONF="$TMP/curl.conf"
# api_call runs inside a command substitution, so a shell variable set there
# would die with the subshell. The message therefore travels through a file.
API_ERROR_FILE="$TMP/api_error"
api_error() { cat "$API_ERROR_FILE" 2>/dev/null; }

if [ "$ACCESS" = "api" ]; then
  # The token goes into a file only this user can read, so it never shows up in
  # the process list where anyone could see it.
  {
    printf 'header = "Authorization: Token token=%s"\n' "$ZAMMAD_TOKEN"
    printf 'header = "Content-Type: application/json"\n'
    printf 'silent\nshow-error\n'
    [ "$SSL_VERIFY" = "false" ] && printf 'insecure\n'
  } > "$CURL_CONF"
  chmod 600 "$CURL_CONF"

  if [ "$SSL_VERIFY" = "false" ] && [ "${ZAMMAD_URL#https://}" != "$ZAMMAD_URL" ]; then
    printf 'WARNING: certificate verification is OFF for %s. The connection is encrypted but unauthenticated; the API token is sent to whoever answers. Only do this on a trusted network.\n' \
           "${ZAMMAD_URL#https://}" >&2
  fi
fi

# Performs one request. On success the body lands on standard output; on any
# other status API_ERROR carries something a human can act on.
api_call() {
  local method="$1" path="$2" body="${3:-}" answer status
  if [ -n "$body" ]; then
    answer="$(curl -K "$CURL_CONF" -m 120 -w '\n%{http_code}' \
                   -X "$method" --data-binary "$body" "$ZAMMAD_URL$path")"
  else
    answer="$(curl -K "$CURL_CONF" -m 120 -w '\n%{http_code}' \
                   -X "$method" "$ZAMMAD_URL$path")"
  fi
  status="$(printf '%s' "$answer" | tail -n1)"
  answer="$(printf '%s' "$answer" | sed '$d')"

  case "$status" in
    2*) printf '%s' "$answer"; return 0 ;;
  esac

  local detail
  detail="$(printf '%s' "$answer" | jq -r '.error? // empty' 2>/dev/null)"
  [ -n "$detail" ] || detail="$(printf '%s' "$answer" | tr -d '\n' | head -c 200)"
  [ "$status" = "000" ] && detail="no answer from $ZAMMAD_URL"
  [ -n "$detail" ] || detail="HTTP $status"
  printf '%s' "$detail" > "$API_ERROR_FILE"
  return 1
}

api_fail() {
  local detail; detail="$(api_error)"
  printf '\nERROR: %s: %s\n' "$1" "$detail" >&2
  case "$detail" in
    *[Tt]oken*|*authenticat*|*"Not authorized"*|*[Pp]ermission*)
      printf '  The token was rejected or is missing a permission.\n' >&2
      printf '  Needed: admin.user and admin.organization, plus admin.role when --role is used.\n' >&2 ;;
    *certificate*)
      printf '  The TLS certificate was rejected. See --no-ssl-verify in the help.\n' >&2 ;;
    *"no answer"*|*resolve*|*refused*)
      printf '  Zammad is not reachable at %s.\n' "$ZAMMAD_URL" >&2 ;;
  esac
  return 1
}

# Walks the pages until one comes back shorter than the page size and writes
# the concatenated array to $2.
#
# The pages are collected in a file rather than in a shell variable, and jq
# reads them from there. Linux caps a single argument at 128 KiB
# (MAX_ARG_STRLEN), which is about sixty users: handing the list to jq with
# --argjson would fail with "Argument list too long" on any real installation.
api_collect() {
  local path="$1" target="$2" size="${3:-$PAGE_SIZE}" want="${4:-0}"
  local page=1 separator count have=0
  local pages="$TMP/pages.json" chunk="$TMP/chunk.json"
  : > "$pages"
  case "$path" in *\?*) separator='&' ;; *) separator='?' ;; esac
  while : ; do
    api_call GET "${path}${separator}per_page=${size}&page=${page}" > "$chunk" || return 1
    count="$(jq 'length' "$chunk" 2>/dev/null)"
    [ -n "$count" ] || { printf '%s' "unexpected answer for $path" > "$API_ERROR_FILE"; return 1; }
    cat "$chunk" >> "$pages"
    printf '\n' >> "$pages"
    have=$(( have + count ))
    [ "$count" -lt "$size" ] && break
    [ "$want" -gt 0 ] && [ "$have" -ge "$want" ] && break
    page=$((page + 1))
  done
  if [ "$want" -gt 0 ]; then
    jq -s -c --argjson want "$want" 'add // [] | .[0:$want]' "$pages" > "$target"
  else
    jq -s -c 'add // []' "$pages" > "$target"
  fi
}

# The condition that /api/v1/users/search understands: no primary organization
# and the field not empty. The key is the model name in the singular
# ("user.organization_id"); the plural is rejected as an invalid selector.
#
# Without a "query" parameter Zammad answers this from the database rather than
# from Elasticsearch, so the result does not depend on the state of the search
# index. That matters for a sync job: a stale index would silently skip users.
user_filter() {
  printf 'condition%%5Buser.%s%%5D%%5Boperator%%5D=is%%20not' "$FIELD"
  printf '&condition%%5Buser.%s%%5D%%5Bvalue%%5D=' "$FIELD"
  if [ "$ONLY_WITHOUT_ORG" = "true" ]; then
    printf '&condition%%5Buser.organization_id%%5D%%5Boperator%%5D=is'
    printf '&condition%%5Buser.organization_id%%5D%%5Bpre_condition%%5D=not_set'
  fi
}

# How many users match $1 (a condition, empty for all of them), or empty if the
# server cannot answer it. One of these costs about as much as fetching a single
# page, and far less than fetching one the script then throws away.
api_count() {
  local query="${1:-}" answer
  answer="$(api_call GET "/api/v1/users/search?${query}${query:+&}only_total_count=true")" || return 1
  printf '%s' "$answer" | jq -r '.total_count // empty' 2>/dev/null
}

# Fetching the users is the expensive part of the API mode, so it is worth two
# cheap questions first: how many users match the filter, and how many are there
# altogether? Counting costs one request each, about as much as a single page.
#
# Measured against Zammad 7.2: a request costs roughly 0.4 s no matter what it
# carries, so the filter only pays when it really saves rows. Hence the rule
#
#   no match at all          fetch nothing - the case a nightly cron run hits
#                            almost every time, and where this saves the most
#   saves at least half      fetch the matching users through /search
#   anything else            fetch the plain list, as before
#
# plus a ceiling of SEARCH_MAX, because /search is capped at 200 per page while
# the plain list carries 1000. On the first run against a fresh field every user
# matches, so the script takes the plain list and is no slower than before.
#
# With --overwrite every user with a filled field is in scope, so there is
# nothing to filter by and the questions are skipped.
#
# If the server does not accept the filter - an older Zammad, a field that does
# not exist, a token without the permission - the run falls back to the plain
# list. That keeps the unknown-field message working, which is reported from
# the full list further down.
collect_api_users() {
  local matching='' total='' want size fetch_started

  matching="$(api_count "$(user_filter)")"

  if [ -z "$matching" ]; then
    : > "$API_ERROR_FILE"   # a refused filter is not the error of the next call
    fetch_started="$(now_ms)"
    api_collect '/api/v1/users' "$TMP/users.json" \
      || { api_fail "cannot read the users"; return 1; }
    FETCH_MS=$(( $(now_ms) - fetch_started ))
    return 0
  fi

  TOTAL_IN_SCOPE="$matching"

  if [ "$matching" -eq 0 ]; then
    printf '[]' > "$TMP/users.json"
    say "  Filter:     on the server, nothing to fetch"
    return 0
  fi

  # A sample only ever needs as many rows as it looks at.
  want="$matching"
  [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$want" ] && want="$LIMIT"

  total="$(api_count)"
  if [ "$want" -lt "$matching" ] \
     || { [ -n "$total" ] && [ "$matching" -le "$SEARCH_MAX" ] \
          && [ "$((matching * 2))" -le "$total" ]; }; then
    size="$SEARCH_PAGE_SIZE"
    [ "$want" -lt "$size" ] && size="$want"
    fetch_started="$(now_ms)"
    api_collect "/api/v1/users/search?$(user_filter)&sort_by=id&order_by=asc" \
                "$TMP/users.json" "$size" "$want" \
      || { api_fail "cannot read the users"; return 1; }
    FETCH_MS=$(( $(now_ms) - fetch_started ))
    say "  Filter:     on the server, $want of $matching user(s) in scope"
  else
    : > "$API_ERROR_FILE"
    fetch_started="$(now_ms)"
    api_collect '/api/v1/users' "$TMP/users.json" \
      || { api_fail "cannot read the users"; return 1; }
    FETCH_MS=$(( $(now_ms) - fetch_started ))
    say "  Filter:     here - $matching of ${total:-all} user(s) in scope, too few to save a fetch"
  fi
}

# Everything the API hands over stays in files for the same reason api_collect
# does: the lists are far too big to travel as command line arguments.
collect_api() {
  printf '[]' > "$TMP/roles.json"
  if [ "$ROLES_JSON" != "[]" ]; then
    api_collect '/api/v1/roles' "$TMP/roles.json" || { api_fail "cannot read the roles"; return 1; }
  fi
  jq -c --argjson want "$ROLES_JSON" \
    '[ .[] | select((.name | ascii_downcase) as $n
                    | $want | map(ascii_downcase) | index($n)) | .id ]' \
    "$TMP/roles.json" > "$TMP/role_ids.json"

  collect_api_users || return 1
  api_collect '/api/v1/organizations' "$TMP/orgs.json" || { api_fail "cannot read the organizations"; return 1; }

  jq -n --slurpfile users_file "$TMP/users.json" --slurpfile orgs_file "$TMP/orgs.json" \
        --slurpfile roles_file "$TMP/roles.json" --slurpfile role_ids_file "$TMP/role_ids.json" \
        --arg field "$FIELD" --argjson only_without "$ONLY_WITHOUT_ORG" '
    ($users_file[0]) as $users
    | ($orgs_file[0]) as $orgs
    | ($roles_file[0]) as $roles
    | ($role_ids_file[0]) as $role_ids
    | ($orgs | map({key: (.id | tostring), value: .name}) | from_entries) as $orgname
    | {
        field_ok: (if ($users | length) == 0 then true else ($users[0] | has($field)) end),
        known_roles: ($roles | map(.name)),
        organizations: ($orgs | map({id, name, active})),
        users: [ $users[]
          | select(.[$field] != null)
          | select(.[$field] | tostring | test("^[[:space:]]*$") | not)
          | select(($only_without == false) or (.organization_id == null))
          | select(($role_ids | length) == 0
                   or ((.role_ids // []) | any(. as $x | $role_ids | index($x))))
          | {
              id, login, firstname, lastname, email,
              field_value: .[$field],
              organization_id,
              organization_name: (if .organization_id == null then null
                                  else $orgname[.organization_id | tostring] end),
              organization_ids: (.organization_ids // [])
            } ]
      }' > "$TMP/data.json"
}

# ── Log records ──────────────────────────────────────────────────────────────
#
# Everything that touches a record is written as one line of fixed fields:
#
#   2026-09-28 22:04:11 | assign | Max Mustermann <max@example.com> | ACME Ltd |
#   timestamp           | action | user                            | orga     | detail
#
# so that a log can be filtered afterwards without parsing prose, for example
#   grep ' | create-orga | ' zammad-orga-sync-*.log
#
# The action is one word and unambiguous:
#
#   create-orga        an organization was created
#   assign             primary organization set, the user had none
#   change             primary organization replaced by a different one
#   unlink-secondary   the organization was taken out of the user's secondary
#                      list so that it could become the primary one
#   skip-no-orga       user left alone, the organization is missing and
#                      --no-create-orgs forbids creating it
#   error-orga         creating an organization failed
#   error-user         writing a user failed
#   plan-*             the same, in a dry run, where nothing was written
#
# A pipe inside an organization name would make that one line ambiguous; the
# script does not escape it, because escaping would be worse to read than the
# case is likely.
record_line() {
  local when
  printf -v when '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null \
    || when="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s | %s | %s | %s | %s' "$when" "$1" "$2" "$3" "${4:-}"
}

record()     { say "$(record_line "$@")"; }
# Failures are reported even under --quiet: a silent run that quietly wrote
# nothing is worse than a noisy one.
record_err() { printf '%s\n' "$(record_line "$@")" >&2; }

# ── Clock and projection ─────────────────────────────────────────────────────
#
# EPOCHREALTIME gives sub-second resolution without starting a process, but it
# exists only in bash 5 and prints the decimal separator of the current locale.
# Where it is missing the run falls back to whole seconds; everything still
# works, the projection just gets coarser.
if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() {
    local stamp="${EPOCHREALTIME/,/.}"
    printf '%s' "$(( ${stamp%.*} * 1000 + 10#${stamp#*.} / 1000 ))"
  }
else
  now_ms() { printf '%s' "$(( $(date +%s) * 1000 ))"; }
fi

# 900 -> "0.9 s", 74000 -> "1 min 14 s", 5400000 -> "1 h 30 min"
human_ms() {
  local ms="${1:-0}"
  if [ "$ms" -lt 10000 ]; then
    printf '%s.%s s' "$((ms / 1000))" "$(( (ms % 1000) / 100 ))"
  elif [ "$ms" -lt 60000 ]; then
    printf '%s s' "$(( (ms + 500) / 1000 ))"
  elif [ "$ms" -lt 3600000 ]; then
    printf '%s min %s s' "$((ms / 60000))" "$(( (ms % 60000 + 500) / 1000 ))"
  else
    printf '%s h %s min' "$((ms / 3600000))" "$(( (ms % 3600000) / 60000 ))"
  fi
}

# One line of the projection table, e.g. "    1000 user(s)          18 s"
project_line() {
  local count="$1" per_user_us="$2" fixed_ms="$3" label="${4:-user(s)}"
  say "$(printf '    %-28s %s' "$count $label" \
                "$(human_ms "$(( fixed_ms + count * per_user_us / 1000 ))")")"
}

# What the run cost, and what that means for a bigger one. Every number here
# was measured on this system a moment ago; nothing comes from a table.
#
# A run has two kinds of cost. Some of it is paid once however big the job is:
# starting Rails, asking for the counts, fetching the organizations. The rest
# grows with the number of users. Only the second kind may be multiplied, which
# is why the Ruby snippets report their own working time and the API layer
# times the fetch itself - otherwise a sample of fifty would scale one Rails
# start into an hour that never happens.
report_timing() {
  local users="$1" read_ms="$2" apply_ms="$3" changes="$4"
  local fixed_ms scaling_ms per_user_us rest

  [ "$users" -gt 0 ] || return 0

  scaling_ms=$(( FETCH_MS + WRITE_MS ))
  fixed_ms=$(( read_ms + apply_ms - scaling_ms ))
  [ "$fixed_ms" -ge 0 ] || fixed_ms=0
  per_user_us=$(( scaling_ms * 1000 / users ))

  say ""
  if [ "$apply_ms" -gt 0 ]; then
    say "Timing: $users user(s) in $(human_ms "$(( read_ms + apply_ms ))") - $(human_ms "$fixed_ms") once, $(human_ms "$scaling_ms") for these users and $changes change(s)"
    say "Projection, reading and writing together - rough, and better the more this run did:"
  else
    say "Timing: $users user(s) in $(human_ms "$read_ms") - $(human_ms "$fixed_ms") once, $(human_ms "$scaling_ms") for these users"
    say "Projection for reading and deciding - rough, and better the larger the sample:"
  fi

  project_line 100 "$per_user_us" "$fixed_ms"
  project_line 1000 "$per_user_us" "$fixed_ms"
  project_line 10000 "$per_user_us" "$fixed_ms"

  if [ -n "$TOTAL_IN_SCOPE" ] && [ "$TOTAL_IN_SCOPE" -gt "$users" ]; then
    rest=$(( TOTAL_IN_SCOPE - users ))
    project_line "$rest" "$per_user_us" "$fixed_ms" "user(s) still in scope"
  fi

  if [ "$apply_ms" -eq 0 ]; then
    say "  Writing is not in these numbers. Measure it with a small real run,"
    say "  for example --limit 20, and the projection covers everything."
  fi
}

# ── Run ──────────────────────────────────────────────────────────────────────
#
# Everything that produces output lives in one function, so that the whole run
# can be piped through tee when a log file is wanted. An "exit" inside then
# ends that pipeline stage and PIPESTATUS carries the status outwards.

main() {
  local created=0 assigned=0 failures=0 unknown_roles name id body answer target
  local user_id who org_id org_name previous secondary line
  local started read_done apply_done read_ms=0 apply_ms=0 users_read=0
  local skipped_missing=0

  started="$(now_ms)"
  say "Zammad organization sync $(date '+%Y-%m-%d %H:%M:%S')"
  say "  Access:     $ACCESS$([ "$ACCESS" = "api" ] && printf ' (%s)' "$ZAMMAD_URL")"
  say "  Field:      $FIELD"
  say "  Roles:      $([ "${#ROLES[@]}" -gt 0 ] && printf '%s ' "${ROLES[@]}" || printf 'all')"
  say "  Overwrite:  $([ "$OVERWRITE" = "true" ] && printf 'yes' || printf 'no')"
  say "  New orgs:   $([ "$CREATE_ORGS" = "true" ] \
                   && { [ "$SHARED" = "true" ] && printf 'created, shared' || printf 'created, not shared'; } \
                   || printf 'NOT created - those users are skipped')"
  say "  Ignoring:   $([ "${#BLACKLIST[@]}" -gt 0 ] && printf '%s ' "${BLACKLIST[@]}" || printf '(nothing)')"
  say "  Mode:       $([ "$DRY_RUN" = "true" ] && printf 'dry run, nothing will be changed' || printf 'changes will be written')"
  [ "$LIMIT" -gt 0 ] && say "  Looking at: at most $LIMIT user(s)$([ "$LIMIT_IMPLICIT" = "true" ] && printf ' - a sample; --limit N widens it, --no-limit drops it')"
  say ""

  # ── Collect ──
  if [ "$ACCESS" = "local" ]; then
    rails_run "$TMP/dump.rb $TMP/config.json" "$TMP/data.json" \
      || { printf '\nERROR: the Rails call produced no data. Command: %s\n' "$RAILS_CMD" >&2; exit 2; }
    TOTAL_IN_SCOPE="$(jq -r '.total_in_scope // empty' "$TMP/data.json")"
    FETCH_MS="$(jq -r '.elapsed_ms // 0' "$TMP/data.json")"
  else
    collect_api || exit 1
  fi

  # ── Early checks ──
  if [ "$(jq -r '.field_ok' "$TMP/data.json")" != "true" ]; then
    printf "\nERROR: This Zammad has no user field called '%s'.\n" "$FIELD" >&2
    printf '       Manage > Objects > User lists the existing fields.\n' >&2
    exit 2
  fi

  unknown_roles="$(jq -r --argjson want "$ROLES_JSON" '
    (.known_roles | map(ascii_downcase)) as $known
    | [ $want[] | . as $w | select($known | index($w | ascii_downcase) | not) ]
    | join(", ")' "$TMP/data.json")"
  if [ -n "$unknown_roles" ]; then
    printf '\nERROR: Unknown role(s): %s\n' "$unknown_roles" >&2
    exit 2
  fi

  # ── Decide, the single implementation ──
  jq --argjson blacklist "$BLACKLIST_JSON" --argjson limit "$LIMIT" \
     --argjson create_orgs "$CREATE_ORGS" \
     -f "$TMP/decide.jq" "$TMP/data.json" > "$TMP/plan.json" \
    || { printf '\nERROR: the decision step failed.\n' >&2; exit 2; }
  # The apply snippet reads the plan as the zammad user.
  [ "$ACCESS" = "local" ] && chmod 644 "$TMP/plan.json" 2>/dev/null

  read_done="$(now_ms)"; read_ms=$(( read_done - started ))
  users_read="$(jq -r '.users | length' "$TMP/data.json")"

  say "Read: ${users_read}$([ -n "$TOTAL_IN_SCOPE" ] && [ "$TOTAL_IN_SCOPE" -gt "$users_read" ] && printf ' of %s' "$TOTAL_IN_SCOPE") user(s) in scope, $(jq -r '.organizations | length' "$TMP/data.json") organization(s) in the system"
  say ""
  say "To do: create $(jq -r '.new_orgs | length' "$TMP/plan.json") organization(s), $(jq -r '.assignments | length' "$TMP/plan.json") assignment(s)"
  while IFS= read -r line; do
    [ -n "$line" ] && say "$line"
  done < <(jq -r '.skipped | to_entries[] | select(.value > 0)
                  | "Skipped: \(.value) (" +
                    ({empty_field: "field empty", blacklisted: "on the ignore list",
                      already_correct: "already assigned correctly",
                      no_organization: "organization does not exist, --no-create-orgs"}[.key] // .key) + ")"' "$TMP/plan.json")

  # Name every record that was left out for want of an organization, so the log
  # answers "why was this user not touched" without a second run.
  skipped_missing="$(jq -r '.missing | length' "$TMP/plan.json")"
  if [ "$skipped_missing" -gt 0 ]; then
    say ""
    while IFS=$'\x1f' read -r who name; do
      [ -n "$who" ] || continue
      record skip-no-orga "$who" "$name" "organization does not exist"
    done < <(jq -r '.missing[] | [.display, .organization_name] | join("\u001f")' "$TMP/plan.json")
  fi
  say ""

  if [ "$(jq -r '.assignments | length' "$TMP/plan.json")" -eq 0 ]; then
    if [ "$skipped_missing" -gt 0 ]; then
      printf 'Nothing to do: %s user(s) skipped for want of an organization.\n' \
             "$skipped_missing"
    else
      say "Nothing to do."
    fi
    report_timing "$users_read" "$read_ms" 0 0
    return 0
  fi

  # ── Apply ──
  if [ "$DRY_RUN" = "true" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      record plan-create-orga "" "$name" \
             "$([ "$SHARED" = "true" ] && printf 'shared' || printf 'not shared')"
      created=$((created + 1))
    done < <(jq -r '.new_orgs[]' "$TMP/plan.json")

    while IFS=$'\x1f' read -r who previous name unlink; do
      [ -n "$who" ] || continue
      [ "$unlink" = "true" ] \
        && record plan-unlink-secondary "$who" "$name" "is a secondary organization"
      if [ -n "$previous" ]; then
        record plan-change "$who" "$name" "is $previous"
      else
        record plan-assign "$who" "$name"
      fi
      assigned=$((assigned + 1))
    done < <(jq -r '.assignments[]
                    | [.display, (.previous // ""), .organization_name,
                       (.unlink | tostring)]
                    | join("\u001f")' "$TMP/plan.json")

  elif [ "$ACCESS" = "local" ]; then
    rails_run "$TMP/apply.rb $TMP/config.json" "$TMP/result.json"
    if [ -s "$TMP/result.json" ]; then
      created="$(jq -r '.created | length' "$TMP/result.json")"
      assigned="$(jq -r '.assigned | length' "$TMP/result.json")"
      failures="$(jq -r '.errors | length' "$TMP/result.json")"
      WRITE_MS="$(jq -r '.elapsed_ms // 0' "$TMP/result.json")"
    else
      failures=1
      printf '  ERROR: the apply step produced no result.\n' >&2
    fi

  else
    WRITE_MS="$(now_ms)"
    # Create the missing organizations first, each exactly once.
    declare -A new_id=()
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      body="$(jq -n --arg n "$name" --argjson s "$SHARED" '{name: $n, shared: $s, active: true}')"
      if answer="$(api_call POST /api/v1/organizations "$body")"; then
        id="$(printf '%s' "$answer" | jq -r '.id')"
        new_id["$name"]="$id"
        created=$((created + 1))
        record create-orga "" "$name" \
               "id $id, $([ "$SHARED" = "true" ] && printf 'shared' || printf 'not shared')"
      else
        failures=$((failures + 1))
        record_err error-orga "" "$name" "$(api_error)"
      fi
    done < <(jq -r '.new_orgs[]' "$TMP/plan.json")

    while IFS=$'\x1f' read -r user_id who org_id org_name previous secondary unlink; do
      [ -n "$who" ] || continue
      target="$org_id"
      [ "$target" = "null" ] && target="${new_id[$org_name]:-}"
      if [ -z "$target" ]; then
        failures=$((failures + 1))
        record_err error-user "$who" "$org_name" "organization missing"
        continue
      fi
      # One PUT carries both changes; the secondary list is only touched when
      # the plan says the target sits in it.
      body="$(jq -n --argjson oid "$target" --argjson sec "$secondary" \
                    --argjson unlink "$unlink" '
        if $unlink then {organization_id: $oid, organization_ids: ($sec - [$oid])}
        else {organization_id: $oid} end')"
      if api_call PUT "/api/v1/users/$user_id" "$body" >/dev/null; then
        assigned=$((assigned + 1))
        [ "$unlink" = "true" ] \
          && record unlink-secondary "$who" "$org_name" "was a secondary organization"
        if [ -n "$previous" ]; then
          record change "$who" "$org_name" "was $previous"
        else
          record assign "$who" "$org_name"
        fi
      else
        failures=$((failures + 1))
        record_err error-user "$who" "$org_name" "$(api_error)"
      fi
    done < <(jq -r '.assignments[]
                    | [ (.user_id | tostring), .display,
                        (if .organization_id == null then "null" else (.organization_id | tostring) end),
                        .organization_name, (.previous // ""), (.secondary_ids | tojson),
                        (.unlink | tostring) ]
                    | join("\u001f")' "$TMP/plan.json")
    WRITE_MS=$(( $(now_ms) - WRITE_MS ))
  fi

  # A dry run prints lines instead of writing, so only a real run has a write
  # time worth projecting from.
  apply_done="$(now_ms)"
  [ "$DRY_RUN" = "true" ] || apply_ms=$(( apply_done - read_done ))

  printf '\nResult%s: %s organization(s) created, %s user(s) assigned, %s%s error(s)\n' \
         "$([ "$DRY_RUN" = "true" ] && printf ' (dry run, nothing changed)')" \
         "$created" "$assigned" \
         "$([ "$skipped_missing" -gt 0 ] && printf '%s skipped for want of an organization, ' "$skipped_missing")" \
         "$failures"

  report_timing "$users_read" "$read_ms" "$apply_ms" "$(( created + assigned ))"

  [ "${failures:-0}" -gt 0 ] && return 1
  return 0
}

if [ -n "$LOG_FILE" ]; then
  main 2>&1 | tee -a "$LOG_FILE"
  RESULT="${PIPESTATUS[0]}"
  printf '\nfinished: %s, exit status %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$RESULT" \
    >> "$LOG_FILE" 2>/dev/null
  say ""
  say "Log written to $LOG_FILE"
else
  main
  RESULT=$?
fi

exit "$RESULT"
