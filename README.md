# Simaky Umbrel App Store

[![Test apps](https://github.com/Simaky/umbrel-app-store/actions/workflows/test-apps.yml/badge.svg)](https://github.com/Simaky/umbrel-app-store/actions/workflows/test-apps.yml)
[![Update Pterodactyl](https://github.com/Simaky/umbrel-app-store/actions/workflows/update-pterodactyl.yml/badge.svg)](https://github.com/Simaky/umbrel-app-store/actions/workflows/update-pterodactyl.yml)
[![Pterodactyl](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2FSimaky%2Fumbrel-app-store%2Fmain%2Fsimaky-pterodactyl%2Fumbrel-app.yml&query=%24.version&label=pterodactyl&color=0e4688)](simaky-pterodactyl)
[![Pterodactyl 2 Beta](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2FSimaky%2Fumbrel-app-store%2Fmain%2Fsimaky-pterodactyl-v2-beta%2Fumbrel-app.yml&query=%24.version&label=pterodactyl%202%20beta&color=orange)](simaky-pterodactyl-v2-beta)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A community app store for [umbrelOS](https://umbrel.com) that runs the
[Pterodactyl](https://pterodactyl.io) game server panel on your Umbrel. Install it in a few clicks:
the panel, database, cache and the Wings daemon are set up for you.

The apps update themselves. A GitHub workflow checks for new Pterodactyl releases every 3 hours,
tests them and publishes the update to this store.

## Apps

| App | Panel | Wings | Panel | Wings API | SFTP | Game ports |
| --- | --- | --- | --- | --- | --- | --- |
| [Pterodactyl](simaky-pterodactyl) | Latest 1.x | Latest 1.x | `8745` | `8746` | `2022` | `25565-25600` |
| [Pterodactyl 2 Beta](simaky-pterodactyl-v2-beta) | Latest 2.x, including betas | Latest | `8755` | `8756` | `2023` | `26565-26600` |

You can install both apps at the same time. Pterodactyl 2.0 is in open beta, so use the stable
app for servers you care about.

## Install

1. In umbrelOS, open the **App Store**.
2. Click the **⋯** button in the top right, then **Community App Stores**.
3. Paste this URL and click **Add**:

   ```text
   https://github.com/Simaky/umbrel-app-store
   ```

4. Open **Simaky App Store** and install **Pterodactyl** or **Pterodactyl 2 Beta**.
5. Open the app and log in. The username is `umbrel`. The password is shown on the app's page
   in umbrelOS.

You can create your first game server right away. Pick an egg, choose the `Umbrel` node and one of
the free ports.

## How it works

Each app runs these containers:

| Container | What it does |
| --- | --- |
| `web` | The Pterodactyl panel (nginx, PHP, queue worker) |
| `db` | MariaDB 11.4 |
| `redis` | Redis 7.4 for cache, sessions and the queue |
| `migrate` | 2.0 only. Runs database migrations on every start, because Panel 2.0 doesn't do it by itself |
| `setup` | Runs once on every start, then exits |
| `wings` | The Wings daemon. It starts game servers as Docker containers on your Umbrel |

On the first start, `setup` creates:

- an admin user `umbrel` (email `umbrel@umbrel.local`),
- a location `umbrel`,
- a node `Umbrel`, sized to your Umbrel's RAM and disk,
- port allocations for game servers,
- the Wings config, connected to the panel.

On later starts, `setup` sees that everything exists and exits. Your changes in the panel are kept.

Game server files are stored in the app's data folder: `app-data/<app-id>/data/wings`.

## Tips

- **Use the panel by IP or Tailscale.** The node address is `umbrel.local`. If you open the panel
  from another address, change the node's FQDN to that address. Otherwise the server console
  can't connect.
- **Need more ports?** Add them in the node's **Allocation** tab. Make sure no other Umbrel app uses them.
- **Before you uninstall**, delete your game servers in the panel. Uninstalling the app doesn't
  remove the game server containers that Wings started.
- **Reset the Wings setup.** Delete `data/wings/config.yml` and `data/wings/.node-id` from the
  app's data folder, then restart the app.
- **Moving from 1.x to 2.0** needs manual steps. Read the
  [upgrade guide](https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1). The stable app
  never moves to 2.0 by itself.

## Automatic updates

The [Update Pterodactyl](.github/workflows/update-pterodactyl.yml) workflow runs every 3 hours.
You can also start it by hand from the **Actions** tab. It runs
[`scripts/update-pterodactyl.ps1`](scripts/update-pterodactyl.ps1), which:

1. Finds the newest `pterodactyl/panel` and `pterodactyl/wings` release for each app.
2. Checks that the image is on `ghcr.io` for both amd64 and arm64. If it isn't yet, it tries again
   on the next run.
3. Pins the image by its digest in `docker-compose.yml`.
4. Updates `version` and `releaseNotes` in `umbrel-app.yml`.
5. Starts the changed app in Docker with [`scripts/smoke-test.sh`](scripts/smoke-test.sh), and
   checks that the panel works and Wings connects to it.
6. Commits and pushes the update to `main`.

umbrelOS then offers the update on your Umbrel. When only Wings changes, the version gets a
`-patch.N` suffix, so umbrelOS still sees a new version.

The [Test apps](.github/workflows/test-apps.yml) workflow runs the same smoke test on every push
and pull request.

> [!NOTE]
> GitHub pauses scheduled workflows in repositories with no activity for 60 days.
> If that happens, turn the workflow back on in the **Actions** tab.

## Development

Repository layout:

```text
.
├── umbrel-app-store.yml           # Store ID and name
├── simaky-pterodactyl/            # Stable app
│   ├── umbrel-app.yml             # App listing for umbrelOS
│   ├── docker-compose.yml         # Containers
│   ├── setup.sh                   # First-start setup
│   └── data/                      # Folders for app data
├── simaky-pterodactyl-v2-beta/    # Beta app, same layout
├── scripts/
│   ├── update-pterodactyl.ps1     # Release updater
│   └── smoke-test.sh              # Docker smoke test
└── .github/workflows/             # CI
```

Run the updater (PowerShell 5.1 or 7):

```powershell
./scripts/update-pterodactyl.ps1        # Update to new releases
./scripts/update-pterodactyl.ps1 -Pin   # Also re-pin the MariaDB and Redis digests
```

Run the smoke test on Linux with Docker, `yq` and `jq`:

```bash
bash scripts/smoke-test.sh simaky-pterodactyl
```

Both apps use the same `setup.sh`. If you change it, copy it to the other app. CI checks that the
two files match.

## Contributing

Bug reports and pull requests are welcome. Please open an
[issue](https://github.com/Simaky/umbrel-app-store/issues) first for larger changes.

Problems with Pterodactyl itself belong in the
[Pterodactyl repositories](https://github.com/pterodactyl).

## License

This repository is released under the [MIT License](LICENSE).

Pterodactyl is made by [Pterodactyl Software](https://pterodactyl.io) and is also MIT licensed.
This store is not affiliated with Pterodactyl or Umbrel.
