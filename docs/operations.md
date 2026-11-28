# How this repository publishes itself

The repository is built and published by `.github/workflows/publish.yml`. It runs
by hand (`workflow_dispatch`) from `main`; it has no `push` or `pull_request`
trigger, because it asks whether the published repository should be rebuilt from
what the products released, not whether code here changed. It has no `schedule`
yet: the daily run is added by the pull request of the first publication, together
with the watcher of that cron.

The input `first_publication` is for an empty bucket only, and it is honoured
only when every object answers 404 and no state is recorded. The input
`expired_state` is described under the recorded state, below.

## The jobs of a publication

| job | needs | what it does | what it holds |
|---|---|---|---|
| `admit` | | reads what the repository serves, downloads the latest release of each product, verifies it against the release key and its provenance, and keeps the verified files; adds the `glyndor-keyring` package | no secret |
| `build` | `admit` | stages the admitted packages and checks the order of versions in the pinned Arch image, with no network | no secret |
| `sign` | `admit`, `build` | judges the tree against what was admitted, writes the database and the state from the manifest, and signs them | `GLYNDOR_PACMAN_GPG_PRIVATE_KEY` |
| `publish` | `admit`, `sign` | reads every signature back, uploads in an order that never leaves a repository that does not hold together, purges the edge cache and reads the repository back from the public address | `GLYNDOR_PACMAN_R2_ACCESS_KEY_ID`, `GLYNDOR_PACMAN_R2_SECRET_ACCESS_KEY`, `GLYNDOR_PACMAN_R2_ENDPOINT`, `GLYNDOR_CF_PURGE_TOKEN`, `GLYNDOR_CF_ZONE_ID` |
| `verify` | `publish` | the install and consistency checks of `reusable-verify-live.yml`, read from `https://pacman.glyndor.net` | nothing |

`sign` and `publish` declare the environment `publish`. Each of the first four jobs
refuses, as its first step, an event that is not `schedule` or `workflow_dispatch`
and a ref that is not `refs/heads/main`; `sign` and `publish` also refuse a
re-run (`run_attempt` other than 1): a publication is started again, not re-run,
because a re-run would write with the state of the first attempt. Two
publications never run at once (`concurrency: publish-pacman`, and a run in flight
is not cancelled). The bucket is `glyndor-pacman`.

## A publication that did not finish

The database group is six objects written one after another (the database, its
signature, their two copies, the state and its signature), and the six writes are
not one. When a write fails, the run puts the previous group back itself. When the
run dies between two writes, because its runner is lost or the job runs out of
time, nothing does: a client cannot verify what is served and the next
publication refuses to start from it.

`publication-notice.yml` opens an issue when a publication that had kept the
artifacts `served` and `signed-tree` ends in anything but success. The issue names
the run and the date the artifacts expire, 14 days after the run.

1. Before that date, run `Recover a publication` (`recover.yml`) from `main` with
   the id of the run. It holds the bucket and the purge credentials and no signing
   key, and it never runs at the same time as a publication.
2. It refuses a run that is not a finished publication from `main`. It writes only
   when each of the six objects is, byte for byte, the one of the previous group or
   the one that run was writing, and the six are neither group whole: then it puts
   the previous group back. A group that is one of the two whole is left as it is.
3. It purges the edge and reads the repository the way the next publication does.
   Then start a new publication. If the recovery says the state it left has expired,
   that publication needs the `expired_state` input with the values the recovery
   printed in "the state published:".

When it refuses because an object is neither, something else wrote to the bucket:
find out what before anything is written. It also writes nothing when the previous
repository of the run is older than the recorded state (below). Once the artifacts
have expired this way back is gone.

## The recorded state, and an expired one

A signature says who wrote a state, not that it is the newest: whoever can write the
bucket can serve an earlier one again. `scripts/metadata/state-floor.txt` records, in
this repository, the sequence and the database of the newest state known to have been
served, and every read of the served repository refuses an earlier one, or none at
all. It says `none` until the first publication. Record the state a publication
signed, in a pull request, once it is served: the file protects up to what it records,
and a read of a newer state says so.

A state lasts 14 days, and every read refuses an expired one. To publish over it:

1. Take its sequence and the sha256 of its database from the line
   `the state published:` in the log of the publication that signed it, or from
   `state-floor.txt` when that records it. Not from what is served: the log and the
   file are what the bucket cannot change.
2. Run `publish.yml` by hand with `expired_state` set to those two, separated by a
   space. That state and no other is read; its signature and database are checked as
   ever, it may not be older than the recorded one, and the upload writes only if the
   bucket still holds it byte for byte.

A recovery whose previous state has expired takes the same input in `recover.yml`,
unless that state is the recorded one. A scheduled run never accepts an expired state,
and neither do `verify` and `verify-live.yml`.

## What the state keeps listed

Nothing replaced is deleted from the bucket, so the state lists every package file
that was ever retired, and the cleanup of each publication counts them with their
size. The list only grows. A state is at most 1 MiB, which is room for about eleven
thousand files: past that `state-make` refuses to write it and nothing is published.
The cleanup also asks the bucket for the size of every file listed and of its
signature, inside the time limit of the `publish` job. A bounded retention, which
this channel does not have yet, is what takes both limits away.

## The other workflows

| workflow | when | what |
|---|---|---|
| `tests.yml` | every pull request | the checks of a pull request that are this repository's own (see [CONTRIBUTING.md](../CONTRIBUTING.md)) |
| `codeql.yml` | pull requests into `main`, pushes to `main`, Mondays 05:23 UTC | the analysis of the workflows and of the Python |
| `freshness.yml` | twice a day (08:13 and 20:13 UTC), pushes to `main`, and pull requests that change the watchers | the watchers of the crons (`codeql.yml` and itself), the watcher of Dependabot, which fails when it has opened no pull request for fifteen days and a pin is behind, and the check that the pinned `shellcheck` and `actionlint` keep up with upstream |
| `recover.yml` | by hand | the previous database group put back over a publication that left it half written, purged and read back (see above) |
| `publication-notice.yml` | the end of a publication | an issue when it did not succeed and may have written, with the run and the date its artifacts expire |
| `verify-live.yml` | by hand | the published repository read from the public address and installed on the Arch the packages were built on (`pinned`) and on the Arch of today (`current`), and that no package of it is older than the one Arch carries (`distro-newer`) |
| `rehearsal.yml` | by hand | the whole publication, twice, with a key and a release made for the run and nothing real in it; it reads no secret and never touches the bucket |

`verify-live.yml` and `rehearsal.yml` have no cron yet, for the same reason as
`publish.yml`.

## Running the publication without the bucket

`tests/rehearsal/rehearse.sh --out <dir> [--install] [--image pinned|current]` is
the rehearsal: the same scripts as `publish.yml`, in the same order, with a bucket
that is a folder behind a server on the loopback and a key made for the run. It
needs a container engine and the network.

## Where the pieces are

| path | what it holds |
|---|---|
| `scripts/admit/` | what is admitted: the products file, the paths each package may install, the scriptlets, the signatures |
| `scripts/assemble/` | the Arch image the packages are built in (`Dockerfile`, by digest), the staging of the tree that is signed, and `floor.txt`, the version floor of each package |
| `scripts/keyring/` | the package `glyndor-keyring` and the check of its bytes |
| `scripts/metadata/` | the database and the state (`glyndor.state`), and the reading of what is served |
| `scripts/sign/` | the signing of the tree |
| `scripts/publish/` | the upload, the purge of the cache and the reading back |
| `scripts/pages/` | the index page and the installers |
| `scripts/verify/` | what a client sees, read from the public address |
| `keyring/` | the public key of the repository and the release keys the admission checks against |
