# Wiki Content Backup

This section instructs how to set-up a weekly backup of your wiki's content, including a XML dump of the text and the text+image content of the wiki alongside a ZIM export of the wiki. You are able to edit most of this to your liking but please note that this was built for [https://foss.wiki](https://foss.wiki) and you may consider a different approach for your wiki.

You can see our live version of this at [https://archive.foss.wiki](https://archive.foss.wiki)

> [!CAUTION]
> As per usual, check ALL the scripts and commands twice before running them, it's the internet after all. I cannot guarantee they work flawlessly.

## Prerequisites

You will need:

- A VPS with shell access, the distro doesn't matter (we use rocky), this does not need to be the server hosting your wiki, but we recommend it to be a different one. It will likely need a fair amount of storage, roughly 4x the size of a single dump but you may need more.
- A dedicated unprivileged user to run the archive as (we use `wikiarchive`), see [Server Setup](#server-setup)
- uv - to install [wikiteam3](https://github.com/saveweb/wikiteam3) and [internetarchive](https://archive.org/developers/internetarchive/cli.html)
- NGINX - any webserver works but you will need to write the config for it
- NGINX Fancy Index
- Certbot - highly recommended for HTTPS
- podman - for [mwoffliner](https://github.com/openzim/mwoffliner) in the script
- rsync - optional for if you want people to be able to mirror your archives
- curl
- zstd

See the full installation commands [here](#full-install-commands).

## Server Setup

The archiver runs as its own unprivileged user, you can skip all this section and just use `root` if you wish, you will just need to run the commands without `sudo -u wikiarchive -H`. You can replace `podman run` with `docker run` if you use `root` but the script will work in `root` with `podman`.

```sh
sudo useradd --system --create-home --home-dir /var/lib/wikiarchive --shell /usr/sbin/nologin wikiarchive
```

Make sure the archive output directory defined in `wiki-archive.sh` is writable by this user and readable by NGINX:

```sh
sudo chown -R wikiarchive:wikiarchive /opt/mirror
sudo chmod 755 /opt/mirror
```

If your distro uses SELinux (RHEL-based) you also need to label it for NGINX:

```sh
sudo semanage fcontext -a -t httpd_sys_content_t '/opt/mirror(/.*)?'
sudo restorecon -R /opt/mirror
```

To configure rootless podman for the script

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 wikiarchive
sudo loginctl enable-linger wikiarchive
```

## Full Install Commands

Make sure you set up the `wikiarchive` user for proper permissions (see [Server Setup](#server-setup). You can do this all as root by just running the command without `sudo -u wikiarchive -H`

RHEL-Based
```sh
sudo dnf install -y epel-release
sudo dnf install -y nginx nginx-mod-fancyindex certbot python3-certbot-nginx rsync zstd curl uv podman

sudo -u wikiarchive -H uv tool install --upgrade wikiteam3
sudo -u wikiarchive -H uv tool install internetarchive
```

Debian-Based
```sh
sudo apt install -y nginx libnginx-mod-http-fancyindex certbot python3-certbot-nginx rsync zstd curl podman

sudo -u wikiarchive -H sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
sudo -u wikiarchive -H /var/lib/wikiarchive/.local/bin/uv tool install --upgrade wikiteam3
sudo -u wikiarchive -H /var/lib/wikiarchive/.local/bin/uv tool install internetarchive
```

## Script Configurations

Make sure to copy `wiki-archive.sh` to `/usr/local/bin/`, make sure to `chmod 755` the script

Before using this, please read and define ALL the configurations at the top of the `wiki-archive.sh` script. The script WILL fail otherwise.

If you wish to not use the IA upload you can comment out:
```sh
upload_to_ia || {
  echo "WARNING: Internet Archive upload failed, continuing" >&2
  IA_FAILED=1
}
```

If your images are all considered as "free" within IA's policies, you may choose to upload the fulldump instead. You can do this by switching `TEXTDUMP_DIR` in the script to `FULLDUMP_DIR` in `upload_to_ia()`, we do not recommend disabling the textdump however

## NGINX Configurations

Make sure to first:
- `header.html` & `index.html` - Copy to `/etc/nginx/wiki-archive/`
- `wiki-archive.conf` - Copy to `/etc/nginx/conf.d/`

You can also customise the `index.html` and `header.html` to your liking, remember to fill out your wiki's information on it as appropriate. `header.html` will appear BEFORE the file index and `index.html` will appear AFTER the file index. Where `wikiname` is listed, put your wiki's name all lowercase no spaces, e.g. `fosswiki`. Where `ARCHIVEDOMAIN` is listed, put the domain serving the archive of your wiki and `WIKI NAME` is for the full name of your wiki.

Finally, remember to add your domain to the `wiki-archive.conf` for NGINX in `server_name YOURDOMAIN;`. It is highly recommended to implement [HTTPS Setup](#https-setup) to secure your archive. You also will need to open port `80/tcp` and if you set up HTTPS port `443/tcp` on your firewall.

### HTTPS Setup

You just need to run `sudo certbot --nginx -d ARCHIVEDOMAIN` when pointing your DNS at your server's IP. You will need to disable proxying on Cloudflare (set to gray cloud) for this to work, there is a workaround using DNS challenges to use proxying (orange cloud) see [here](https://certbot-dns-cloudflare.readthedocs.io/en/stable/) for more on this.

## Timer Setup

You can also use crontab for this, but we prefer systemd timers. Make sure to copy `wiki-archive.service` and `wiki-archive.timer` into `/etc/systemd/system/`.

To change the time of the script running, update `OnCalendar=Mon 02:00 UTC` in `wiki-archive.timer`. We suggest doing it at the point of lowest traffic on your wiki. Remember to update the HTML pages with the new time, ideally in UTC as the JS will update it client-side for the user.

Then to start the timer:
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now wiki-archive.timer
```

You can run it manually and follow it with:
```sh
sudo systemctl start --no-block wiki-archive.service
journalctl -fu wiki-archive.service
```

## Internet Archive Setup

Make sure you set up the `wikiarchive` user in for proper permissions (see [Server Setup](#server-setup)). You can do this all as root by just running the command without `sudo -u wikiarchive -H`.

You will need to create an account on [archive.org](https://archive.org) and use its credentials here, we suggest making an account just for your wiki to upload the archives.

```sh
sudo -u wikiarchive -H /var/lib/wikiarchive/.local/bin/ia configure
```

## rsync Setup

First copy `rsyncd.conf` to `/etc/rsyncd.conf` then you will need to open port `873/tcp` on your firewall after installing rsync. Make sure to add your wiki name to the config.

Create and fill in `/root/rsync-motd.txt` with an appropriate description of your archive's purpose.

If your distro uses SELinux (RHEL-based) you will need to run `sudo setsebool -P rsync_export_all_ro 1` after installation of rsync.

You will have to point your DNS directly at your server, you cannot proxy via Cloudflare. Set the DNS record to the gray-cloud if you use Cloudflare.

## Troubleshooting

Is the timer scheduled - `systemctl list-timers wiki-archive.timer`

Is the service running - `systemctl status wiki-archive.service`

Follow the live output - `journalctl -fu wiki-archive.service`

Review the previous run - `journalctl -u wiki-archive.service --since "7 days ago"`

Check the status of the last run (0=success) - `systemctl show wiki-archive.service -p Result -p ExecMainStatus`
