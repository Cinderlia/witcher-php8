# Witcher PHP 8.4 — one-click installer

Builds PHP 8.4 with the Witcher patch (AFL fork server + CGI opcode tracing)
and installs Xdebug. Equivalent to the PHP 7 setup in `../php7/`.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-click build + install script |
| `php-8.4-witcher.patch` | Patch applied to stock PHP 8.4 source |
| `zend_witcher_trace.c` | AFL fork server + CGI tracer implementation |
| `zend_witcher_trace.h` | Header for the tracer (included by `zend_execute.c`) |

## Quick start

```bash
./install.sh                          # install to /usr/local, source in /phpsrc8
./install.sh --prefix /opt/php84 --source /phpsrc8-test   # custom paths
./install.sh --skip-download --skip-deps                   # rebuild in-place
WITCHER_DEBUG=1 ./install.sh --skip-download --skip-deps  # debug output to stderr
```

## What install.sh does

1. Installs build dependencies (`apt-get`)
2. Downloads and SHA-256-verifies the PHP 8.4.x tarball from php.net
3. Copies `zend_witcher_trace.{c,h}` into `Zend/`
4. Applies `php-8.4-witcher.patch` (idempotent — safe to re-run)
5. Runs `buildconf --force` and `configure` with CGI + common extensions
6. Builds with `make -j$(nproc)` — binaries land in `sapi/cgi/php-cgi` and `sapi/cli/php`
7. Installs system-wide with `sudo make install`
8. Builds and installs **Xdebug** (`zend_extension` set to `coverage` mode)
9. Writes `php.ini` with `cgi.force_redirect = 0` so `php-cgi` can be called directly by AFL

## What the patch does

| File | Change |
|------|--------|
| `configure.ac` | Adds `zend_witcher_trace.c` to the Zend build sources |
| `Zend/zend_execute.c` | Includes `zend_witcher_trace.h` to wire in the VM trace hooks |
| `sapi/cgi/cgi_main.c` | Calls `witcher_cgi_trace_init()` at CGI startup |

The tracer starts an **AFL fork server** on fd 198/199, reads
`Cookie`, `QUERY_STRING`, and POST body from stdin (null-separated),
sets the CGI environment, then forks a child per AFL iteration.
Opcode-level coverage is written to the AFL shared-memory bitmap.

## Requirements

- Ubuntu 18.04+ with `sudo`
- autoconf 2.69+, `patch`, `curl`, `wget`
- Apache dev headers (`apache2-dev`) for the `mod_php` SAPI
- libcurl ≥ 7.61 to re-enable `--with-curl` (currently omitted)
