# How this repository publishes itself

The repository is built and published by `.github/workflows/publish.yml`. It runs
by hand (`workflow_dispatch`) from `main`; it has no `push` or `pull_request`
trigger, because it asks whether the published repository should be rebuilt from
what the products released, not whether code here changed. It has no `schedule`
yet: the daily run is added by the pull request of the first publication, together
with the watcher of that cron.

The input `first_publication` is for an empty bucket only, and it is honoured
only when every object answers 404.

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

## The other workflows

| workflow | when | what |
|---|---|---|
| `tests.yml` | every pull request | the checks of a pull request that are this repository's own (see [CONTRIBUTING.md](../CONTRIBUTING.md)) |
| `codeql.yml` | pull requests into `main`, pushes to `main`, Mondays 05:23 UTC | the analysis of the workflows and of the Python |
| `freshness.yml` | twice a day (08:13 and 20:13 UTC), pushes to `main`, and pull requests that change the watchers | the watchers of the crons (`codeql.yml` and itself) and the check that the pinned `shellcheck` and `actionlint` keep up with upstream |
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
