# Wiki Database Backup

This section explains how to set up a daily backup of your wiki's database, saved to an S3-compatible provider of your choice. It dumps the database, compresses it, encrypts it, and uploads it. This is ONLY for MariaDB or MySQL databases.

### Notes

It runs as an unprivileged system user, however you can choose to run it as root if you prefer but there is not much need to. If you do so, you will need to modify the commands accordingly to just run as the root user.

In theory this should work with rclone and any remote storage, but S3-compatible storage is best suited for this purpose.

> [!CAUTION]
> As per usual, check ALL the scripts and commands twice before running them. It's the internet after all, and I cannot guarantee they work flawlessly.

> [!IMPORTANT]
> Once set up, VERIFY that it works by running the script manually and checking the output in your S3 bucket. Download the backup, decrypt and extract it, and restore it to a test database. DO NOT just assume it works.
>
> You can check a local backup with the `backup-check.sh` script. Pass the `.sql.gz.gpg` file as the first argument, and you will be prompted for the passphrase. It will then check the SQL file and report back. You should aim to do this regularly to ensure your backups are working.

## Prerequisites

You will need:

- Shell access to the server hosting your database. This should work for containerised setups as well, but you will need to modify the scripts accordingly.
- A S3-compatible provider
- rclone
- gnupg
- gzip

See the full installation commands [here](#full-install-commands).

## Full Install Commands

This assumes MySQL or MariaDB is already installed and running on the server.

RHEL-Based
```sh
sudo dnf install -y rclone gnupg gzip
```

Debian-Based
```sh
sudo apt install -y rclone gnupg gzip
```

## S3 Setup

### Bucket Setup

This varies by provider, but the credentials should still be an account ID and account key. You may not have every option listed below, but enforce all of them if you can. We use [Backblaze B2](https://www.backblaze.com/cloud-storage), which provides all the features configured below, but most S3-compatible providers should work. The compatible ones are listed [here](https://rclone.org/s3/), for Backblaze you will use a seperate config.

1. Create a bucket. We called ours `db-backup`, but you can call it anything. You may need to complete some or all of steps 2 to 4 during creation of the bucket. Note the name for the script later.
2. Set the bucket to private, inaccessible outside the API.
3. Enable object locking for an acceptable number of days, which sets how many copies are kept. This prevents backups from being modified. We set it to `29`.
4. Set lifecycle rules one day longer than the object lock, so old backups are removed. On some providers you must "hide" an item first. We hide after `30` days and delete `1` day after hiding.
5. Create a key scoped to this bucket. It requires read/write access to work properly. Limit the key to only the bucket it needs. You will get a Key ID and a Key Secret. Store these safely.

## Create the Backup User

Create a system user with no login shell, and a home directory for its GPG keyring and rclone state:

```sh
sudo useradd --system --create-home --home-dir /var/lib/db-backup --shell /usr/sbin/nologin db-backup
sudo mkdir -p /etc/db-backup
sudo chown root:db-backup /etc/db-backup
sudo chmod 750 /etc/db-backup
```

## Database User Setup

Create a read-only backup user in MySQL/MariaDB. Replace `PASSWORD` with a strong password, `USERNAME` with a username of your choice, and `DB_NAME` with your database name. You will need the database root password for this step.

```sh
sudo mysql -u root -p -e "GRANT PROCESS ON *.* TO '${USERNAME}'@'localhost' IDENTIFIED BY '${PASSWORD}'; GRANT SELECT, LOCK TABLES, SHOW VIEW ON ${DB_NAME}.* TO '${USERNAME}'@'localhost'; FLUSH PRIVILEGES;"
```

Afterwards, remove the command from your shell history so the password is not left behind. Run `history -d $((HISTCMD-1))` in the same shell session.

Create the credentials file in `/etc/db-backup/my.cnf`:
```conf
[mysqldump]
user=USERNAME
password=PASSWORD
host=localhost
```

Make root the owner, with the `db-backup` group able to read the file:
```sh
sudo chown root:db-backup /etc/db-backup/my.cnf
sudo chmod 640 /etc/db-backup/my.cnf
```

## rclone Setup

Place your rclone config in `/etc/db-backup/rclone.conf`:
```sh
sudo chown root:db-backup /etc/db-backup/rclone.conf
sudo chmod 640 /etc/db-backup/rclone.conf
```

Fill it in using the `backblaze-rclone.conf` or `s3-rclone.conf` template. Use the section header name for your provider, and for `providername` use the name listed in [the rclone S3 standard options](https://rclone.org/s3/#standard-options). Some providers need extra options, so check the section for your provider on that page.

Then verify it as the backup user. Replace `SECTION_NAME` and `BUCKET_NAME` with your section header and bucket name:

```sh
sudo -u db-backup rclone --config /etc/db-backup/rclone.conf lsd SECTION_NAME:BUCKET_NAME
```

## Encryption Key Setup

DO NOT ever store the private key on the server. Keep it securely stored locally. We use a GPG key pair to encrypt backups before upload, but you can use any encryption method you prefer.

On your local machine, create a key pair:
```sh
gpg --full-generate-key
```

We suggest using the default key type (ECC sign and encrypt) and elliptic curve (1). You can choose to set an expiry date, but if you do, remember to update the key on the server when it expires otherwise the backup will fail.

When prompted for a name and email, we suggest a service email under the wiki domain and a comment like `MediaWiki DB Backup`. Set a strong passphrase and store it securely. Note the key ID that is returned, as you will need it.

Export only the public key. NEVER export or upload the private key to the server:
```sh
gpg --export --armor <keyid> > db-backup.pub.asc
```

Copy the public key to the server, to a location the `db-backup` user can read, such as `/tmp`:
```sh
scp db-backup.pub.asc user@server:/tmp/db-backup.pub.asc
```

Import the key as the `db-backup` user and check it has imported
```sh
sudo -H -u db-backup gpg --import /tmp/db-backup.pub.asc
sudo -H -u db-backup gpg --list-keys
```

Delete the public key copy from `/tmp`:
```sh
sudo rm -f /tmp/db-backup.pub.asc
```

## Backup Script Setup

Copy the `db-backup.sh` script into `/usr/local/bin/db-backup.sh` and replace the configs at the top with your own values, then make it executable:
```sh
sudo chmod 775 /usr/local/bin/db-backup.sh
```

## Systemd Timer Setup

You can also use crontab for this, but we prefer systemd timers. To set it up create the service unit by copying `db-backup.service` and `db-backup.timer` into `/etc/systemd/system/`.

You can change the timer schedule to the time of your lowest wiki activity.

To set-up the timer you can use:
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now db-backup.timer
```

## Verify the Backup Works

Run the backup manually and follow the output:
```sh
sudo systemctl start --no-block db-backup.service
journalctl -fu db-backup.service
```

Check the S3 bucket for the new object. Download it, run `backup-check.sh` against it, and restore it to a test database. Only trust the backup once you have restored it at least once successfully.

## Troubleshooting

Is the timer scheduled - `systemctl list-timers db-backup.timer`

Is the service running - `systemctl status db-backup.service`

Follow the live output - `journalctl -fu db-backup.service`

Review the previous run - `journalctl -u db-backup.service --since "24 hours ago"`

Check the status of the last run (0=success) - `systemctl show db-backup.service -p Result -p ExecMainStatus`

