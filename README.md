# moodle-docker

[Moodle](https://moodle.org) on **NGINX + PHP-FPM**, built as two images from one
`Dockerfile`:

| Image | Target | Runs as | Listens |
|---|---|---|---|
| `ghcr.io/magnus1990p/moodle-fpm` | `fpm` | `www-data` (33) | `127.0.0.1:9000` |
| `ghcr.io/magnus1990p/moodle-nginx` | `nginx` | `nginx` (101) | `8080` |

Both images contain the **same Moodle codebase at `/var/www/moodle`**, so NGINX
serves static files from its own copy and passes PHP requests to FPM with
matching paths. No shared code volume is needed. The Moodle source isn't stored
in this repo: it's fetched from [moodle/moodle](https://github.com/moodle/moodle)
during every build. The build also runs
`composer install --no-dev --classmap-authoritative`, because Moodle 5.1+ won't
start without its Composer `vendor/` directory.

## Versions and tags

The workflow ([.github/workflows/build.yml](.github/workflows/build.yml)) runs on
every push to `main` and on manual dispatch:

- `moodle_version`: a release number such as `5.2.1`, or `latest` (default). `latest`
  resolves to the newest stable release tag and skips betas and RCs.
- `php_version`: PHP version for the `fpm` image (default `8.4`). Check the
  [release notes](https://moodledev.io/general/releases) for the range each Moodle
  release supports.

Each build pushes the tags `<x.y.z>`, `<x.y>` and, for `latest` builds only, `latest`.
The Moodle version inside an image is recorded in `/var/www/moodle/.image-version`.
**Pin deployments to `<x.y.z>`**: a Moodle version change needs a database upgrade
(`admin/cli/upgrade.php`), so it should be a deliberate step.

The base images use rolling tags (`php:<ver>-fpm`, `nginx-unprivileged:stable-alpine`),
so rebuilding also picks up OS and PHP security patches.

Local build:

```sh
docker build --target fpm   --build-arg MOODLE_VERSION=5.2.1 -t moodle-fpm .
docker build --target nginx --build-arg MOODLE_VERSION=5.2.1 -t moodle-nginx .
```

With `MOODLE_VERSION=latest`, a local build can reuse a cached source layer from an
older release. Pass an explicit version or `--no-cache`. CI always passes the
resolved version, so it doesn't have this problem.

## Running

The two containers must share a network namespace, because NGINX reaches FPM on
`127.0.0.1:9000`. In Kubernetes, that means one pod. What you provide:

| Path (fpm container) | What |
|---|---|
| `/var/www/moodle/config.php` | Your `config.php` (e.g. a ConfigMap mounted via `subPath`). **Required.** |
| `/var/moodledata` | Persistent moodledata, writable by UID/GID 33 (e.g. `fsGroup: 33`) |
| `/var/cache/moodle` | Optional node-local cache (emptyDir) for `localcachedir`/`cachedir`/`tempdir` |

FPM keeps the container environment (`clear_env = no`), so `config.php` can read
secrets with `getenv()`:

```php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'mariadb';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = getenv('MOODLE_DB_USER');
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbpersist' => false, 'dbport' => 3306, 'dbcollation' => 'utf8mb4_unicode_ci'];

$CFG->wwwroot   = 'https://moodle.example.com';   // no /public
$CFG->sslproxy  = true;                           // TLS terminated in front of NGINX
$CFG->dataroot  = '/var/moodledata';
$CFG->localcachedir = '/var/cache/moodle/local';
$CFG->cachedir      = '/var/cache/moodle/cache';
$CFG->tempdir       = '/var/cache/moodle/temp';
$CFG->session_handler_class = '\core\session\database';
$CFG->routerconfigured = true;                    // NGINX falls back to /r.php
$CFG->admin = 'admin';
$CFG->directorypermissions = 02777;

require_once(__DIR__ . '/lib/setup.php');
```

**Cron:** run the `fpm` image as a second container with the same mounts, and
this command:
`sh -c 'while true; do php /var/www/moodle/admin/cli/cron.php; sleep 60; done'`

**First install:**
`php /var/www/moodle/admin/cli/install_database.php --agree-license --fullname=... --shortname=... --adminuser=admin --adminpass=... --adminemail=...`
Run it inside the fpm container. The CLI scripts stay outside `public/`.
