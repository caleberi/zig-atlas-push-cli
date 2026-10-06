# zig-atlas-push-cli

Zig reimplementation of the [atlas-app-services-cli](https://www.npmjs.com/package/atlas-app-services-cli) npm installer/wrapper.
It downloads the official `appservices` binary and forwards CLI args to it — **no Node or npm required**.

Requires [Zig 0.16+](https://ziglang.org/download/).

## Install

```bash
zig build postinstall
```

That builds `atlas-push-cli`, reads `package.toml` for the target version, fetches the matching archive from MongoDB’s MANIFEST, and extracts `appservices` into `zig-out/bin/`.

Put `zig-out/bin` on your `PATH`, or call the binaries directly:

```bash
./zig-out/bin/appservices --help
./zig-out/bin/atlas-push-cli --help   # same thing; forwards to appservices
```

## Usage

```bash
# Forward any appservices command through the wrapper
zig build run -- login
zig build run -- app create --name my-app
./zig-out/bin/atlas-push-cli whoami
```

### Logging in

```bash
appservices login
```

Opens Atlas Access Manager so you can create an API key; paste the public/private key into the CLI prompts.

### Blank-slate app

```bash
appservices app create --name <your app name>
```

Defaults when omitted:

- [`--deployment-model`](https://www.mongodb.com/docs/atlas/app-services/apps/deployment-models-and-regions/#deployment-models): `GLOBAL`
- [`--provider-region`](https://www.mongodb.com/docs/atlas/app-services/apps/deployment-models-and-regions/#cloud-deployment-regions): `aws-us-east-1`

### Template starter

```bash
appservices app create --name myApp --template sync.todo --cluster myCluster1
```

Template apps need a provisioned Atlas cluster. Full list: [template apps](https://www.mongodb.com/docs/atlas/app-services/reference/template-apps/#template-apps-available).

## Build steps

| Step | What it does |
| --- | --- |
| `zig build` | Build `atlas-push-cli` + install `package.toml` into `zig-out/bin` |
| `zig build postinstall` | Download & extract `appservices` (npm `install.js` equivalent) |
| `zig build run -- <args>` | Forward args to `appservices` (npm `wrapper.js` equivalent) |
| `zig build test-install` | Smoke-test the download/extract flow |
| `zig build test` | Unit tests |

## How it maps to the npm package

| npm | this project |
| --- | --- |
| `package.json` version | `package.toml` |
| `install.js` | `atlas-push-cli --postinstall` → `src/install.zig` |
| `wrapper.js` | `atlas-push-cli [args…]` → `src/launch.zig` |
| `testInstall.js` | `atlas-push-cli --test-install` → `src/verify.zig` |

Pin the downloaded CLI version by editing `version` in `package.toml` (must match a MANIFEST / `past_releases` entry).

## Setup docs

See the [MongoDB Atlas App Services CLI docs](https://www.mongodb.com/docs/atlas/app-services/cli/) for app layout and configuration details.

## Tips

1. Track app config with `git` — [automatic deployments](https://www.mongodb.com/docs/atlas/app-services/apps/#automate-deployment) can sync from git.
2. Run functions locally with `appservices function run`.
