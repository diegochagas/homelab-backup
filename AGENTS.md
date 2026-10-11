# Working on homelab-backup

Shell only, no build step. The ZimaOS-side scripts (`zimaos/`) are POSIX `sh`
(ZimaOS's `/bin/sh` is not bash); the workstation scripts are bash.

## Testing

- `scripts/check` is the gate: shellcheck (zero warnings — an explicit
  `# shellcheck disable=` needs a reason), shfmt when installed, `tests/run.sh`.
- Every change to `zimaos/` logic gets a test in `tests/run.sh`. Tests run
  against a fake `/sys`, `/dev` and the fake commands in `tests/fakes/`; add a
  fake rather than letting a test reach the real system. Set `TELEGRAM_ENV`
  to a missing file (run.sh already does) so `notify.sh` stays silent.
- Risk class: data deletion / system changes. Scenario tests cover: rsync
  failure mid-run (apps restarted, drive detached, flag kept), backup drive
  missing at failover (apps left stopped), reboot during failover, dry runs
  touching nothing, missing config → non-zero exit.
- No real paths, IPs, UUIDs or tokens in code, tests, examples or README.
  Config lives in gitignored `config.sh` / `zimaos/config.sh` / `telegram.env`.
- Pre-push hook: `git config core.hooksPath .githooks`.

## Rollback

Revert the commit and rerun `sudo ./zimaos/install-timer.sh` on the server
(it re-installs or removes the failover timer according to `config.sh`).
