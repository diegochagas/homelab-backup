# Working on homelab-backup

Shell only, no build step. The ZimaOS-side scripts (`zimaos/`) are POSIX `sh`
(ZimaOS's `/bin/sh` is not bash); the workstation scripts are bash.

## Testing

- `scripts/check` is the gate: shellcheck (zero warnings — an explicit
  `# shellcheck disable=` needs a reason), shfmt when installed, `tests/run.sh`.
- Every change to `zimaos/` logic or to a workstation script gets a test in
  `tests/run.sh`. Tests run against a fake `/sys`, `/dev` and the fake commands
  in `tests/fakes/` (the workstation scripts are copied to a temp dir with
  `lib/` and a test `config.sh` by `mint_setup`); add a fake rather than
  letting a test reach the real system. Set `TELEGRAM_ENV` to a missing file
  (run.sh already does) so `notify.sh` stays silent.
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

## Clean code (dev-playbook CLEAN-CODE.md)

Language: bash on the workstation, POSIX `sh` under `zimaos/`. Formatter: `shfmt -i 4 -ci`
(run by `scripts/check`); don't discuss style.

- Functions 4–20 lines, one verb each. Files ≤300 lines, hard max 500. The workstation scripts are
  thin entry points over sourced `lib/*.sh` (like `zimaos/lib/drive.sh`); `scripts/clean-code-audit
  --strict` in `scripts/check` fails on any function or file over the limit. A heredoc-only help
  function opts out with `# clean-code-audit: allow-long -- <reason>` on the line above it.
- One responsibility per file: one script per stage (see the README chain), shared helpers in `lib/`
  (`output`, `logging`, `config-loader`, `remote`, `transfer`, `disk-space`, `telegram`, `arguments`,
  `preflight`, `summary`), script-specific stages in `lib/backup-*.sh` / `lib/restore-*.sh`.
- Names specific and searchable (<5 grep hits): `drive_detach`, `restore_appdata`, not `run`, `do_it`, `tmp`.
- Validate every input and config value (`[ -n "$X" ]`, numeric checks, paths exist) before using it;
  missing config → clear message and non-zero exit.
- Early returns / guard clauses, max 2 nested levels. Extract duplicated rsync/ssh invocations into one helper.
- Errors name the offending value and the expected shape (`BACKUP_DEST "/mnt/x" is not a mounted directory`).
- Comments: keep the ones you find (they record ZimaOS quirks). Write WHY, cite issue numbers / SHAs.
  Each function gets a one-line header comment with its purpose and an example call.
- External commands (rsync, ssh, docker, flock, notify) go through thin wrapper functions so `tests/fakes/`
  can replace them; no test touches the real system.
- Logging: plain text lines prefixed with the stage name (these are CLIs read by a human and Telegram).
- Defensive code this repo needs (flag anything else instead of adding it silently): lock file against
  concurrent runs (flock, as in `zimaos/backup.sh`); free-space check before copying; never delete the last
  verified-good copy; never write into the source; restart apps even when rsync fails; Telegram notify on failure.
- README keeps "The Backup Chain" diagram current; update it when the shape changes.
- `scripts/check` is the single validation command.
