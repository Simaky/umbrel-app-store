# Simaky Umbrel App Store

[![Test apps](https://github.com/Simaky/umbrel-app-store/actions/workflows/test-apps.yml/badge.svg)](https://github.com/Simaky/umbrel-app-store/actions/workflows/test-apps.yml)
[![Update apps](https://github.com/Simaky/umbrel-app-store/actions/workflows/update-apps.yml/badge.svg)](https://github.com/Simaky/umbrel-app-store/actions/workflows/update-apps.yml)
[![Pterodactyl](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2FSimaky%2Fumbrel-app-store%2Fmain%2Fsimaky-pterodactyl%2Fumbrel-app.yml&query=%24.version&label=pterodactyl&color=0e4688)](simaky-pterodactyl)
[![Pterodactyl 2 Beta](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2FSimaky%2Fumbrel-app-store%2Fmain%2Fsimaky-pterodactyl-v2-beta%2Fumbrel-app.yml&query=%24.version&label=pterodactyl%202%20beta&color=orange)](simaky-pterodactyl-v2-beta)
[![Newt](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2FSimaky%2Fumbrel-app-store%2Fmain%2Fsimaky-newt%2Fumbrel-app.yml&query=%24.version&label=newt&color=f36a21)](simaky-newt)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A community app store for [umbrelOS](https://umbrel.com). It runs the
[Pterodactyl](https://pterodactyl.io) game server panel on your Umbrel, and the
[Newt](https://github.com/fosrl/newt) connector that shares your Umbrel's apps and game servers
through your own [Pangolin](https://pangolin.net) server.

The apps update themselves. A GitHub workflow checks for new releases every 3 hours, tests them
and publishes the update to this store.

## Apps

### Pterodactyl

Everything is set up for you: the panel, database, cache and the Wings daemon.

| App | Panel | Wings | Panel | Wings API | SFTP | Game ports |
| --- | --- | --- | --- | --- | --- | --- |
| [Pterodactyl](simaky-pterodactyl) | Latest 1.x | Latest 1.x | `8745` | `8746` | `2022` | `25565-25600` |
| [Pterodactyl 2 Beta](simaky-pterodactyl-v2-beta) | Latest 2.x, including betas | Latest | `8755` | `8756` | `2023` | `26565-26600` |

You can install both apps at the same time. Pterodactyl 2.0 is in open beta, so use the stable
app for servers you care about.

### Newt for Pangolin

| App | Version | Setup page |
| --- | --- | --- |
| [Newt for Pangolin](simaky-newt) | Latest Newt | `8767` |

Newt makes an outgoing, encrypted connection from your Umbrel to a Pangolin server, for example on
a VPS. Pangolin then serves your apps on your domain with HTTPS, and forwards TCP and UDP ports for
game servers. You don't need to open any ports on your home router. See [Newt setup](#newt-setup).

## Install

1. In umbrelOS, open the **App Store**.
2. Click the **⋯** button in the top right, then **Community App Stores**.
3. Paste this URL and click **Add**:

   ```text
   https://github.com/Simaky/umbrel-app-store
   ```

4. Open **Simaky App Store** and install the apps you want.

For Pterodactyl, open the app and log in. The username is `umbrel`. The password is shown on the
app's page in umbrelOS. You can create your first game server right away: pick an egg, choose the
`Umbrel` node and one of the free ports.

## Newt setup

You need a Pangolin server. To run your own, follow the
[Pangolin install guide](https://docs.pangolin.net/self-host/quick-install) on a VPS with a public IP.

1. In Pangolin, open your organization, go to **Sites** and create a site of type **Newt**.
2. Open **Newt for Pangolin** on your Umbrel. Paste the Pangolin address, the site ID and the
   site secret, then click **Save and connect**. The status changes to **Connected**.
3. In Pangolin, add resources for this site. Newt uses host networking, so the target address is
   `localhost`:
   - a website or app: an HTTP resource, for example `panel.example.com` to `localhost:8745`,
   - a Minecraft server: a TCP resource on port `25565` to `localhost:25565`.

Raw TCP and UDP ports also need an entry point in Pangolin's Traefik config and an open port in the
VPS firewall. See [Raw TCP and UDP](https://docs.pangolin.net/manage/resources/tcp-udp-resources).

The setup page is behind the umbrelOS login, because it stores the site secret.

## How it works

### Pterodactyl

Each Pterodactyl app runs these containers:

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

### Newt

| Container | What it does |
| --- | --- |
| `web` | The setup page (BusyBox httpd). Saves the site details to `data/site.json` |
| `newt` | Newt on the host network. Starts once `data/site.json` exists and restarts when it changes |

## Pterodactyl tips

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

The [Update apps](.github/workflows/update-apps.yml) workflow runs every 3 hours.
You can also start it by hand from the **Actions** tab. It runs
[`scripts/update-apps.ps1`](scripts/update-apps.ps1), which:

1. Finds the newest release for each app: `pterodactyl/panel` and `pterodactyl/wings` for
   Pterodactyl, `fosrl/newt` for Newt.
2. Checks that the image is published for both amd64 and arm64. If it isn't yet, it tries again
   on the next run.
3. Pins the image by its digest in `docker-compose.yml`.
4. Updates `version` and `releaseNotes` in `umbrel-app.yml`.
5. Starts the changed app in Docker with [`scripts/smoke-test.sh`](scripts/smoke-test.sh). For
   Pterodactyl it checks that the panel works and Wings connects to it. For Newt it checks that the
   setup page saves the details and Newt starts.
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
├── simaky-newt/                   # Newt app
│   ├── run-newt.sh                # Starts Newt with the saved site details
│   └── www/cgi-bin/index.cgi      # Setup page
├── scripts/
│   ├── update-apps.ps1            # Release updater
│   ├── smoke-test.sh              # Docker smoke test (Pterodactyl)
│   └── smoke-test-newt.sh         # Docker smoke test (Newt)
└── .github/workflows/             # CI
```

Run the updater (PowerShell 5.1 or 7):

```powershell
./scripts/update-apps.ps1        # Update to new releases
./scripts/update-apps.ps1 -Pin   # Also re-pin the MariaDB, Redis and BusyBox digests
```

Run the smoke test on Linux with Docker and `yq`:

```bash
bash scripts/smoke-test.sh simaky-pterodactyl
bash scripts/smoke-test.sh simaky-newt
```

Both Pterodactyl apps use the same `setup.sh`. If you change it, copy it to the other app. CI checks that the
two files match.

## Contributing

Bug reports and pull requests are welcome. Please open an
[issue](https://github.com/Simaky/umbrel-app-store/issues) first for larger changes.

Problems with Pterodactyl or Pangolin themselves belong in the
[Pterodactyl](https://github.com/pterodactyl) or [Fossorial](https://github.com/fosrl) repositories.

## License

This repository is released under the [MIT License](LICENSE).

Pterodactyl is made by [Pterodactyl Software](https://pterodactyl.io) (MIT). Pangolin and Newt are
made by [Fossorial](https://github.com/fosrl); Newt is AGPL-3.0. This store is not affiliated with
Pterodactyl, Fossorial or Umbrel.
