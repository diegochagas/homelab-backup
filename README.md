# homelab-backup

Scripts and documentation for backing up and restoring homelab services.

## Project Structure

- `.github/`: GitHub templates and workflows.
- `docs/`: Architecture, installation, backup, restore, configuration, and roadmap documentation.
- `config/`: Example configuration files.
- `assets/`: Project assets.
- `internal/`: Shared shell modules.
- `platforms/`: Platform-specific helpers.
- `services/`: Service-specific backup definitions.
- `tests/`: Test scripts and fixtures.
- `examples/`: Example configurations and workflows.
- `logs/`: Runtime logs, ignored by default.

## Getting Started

```bash
cp config/config.env.example config/config.env
./install.sh
```

## Development

```bash
make lint
make verify
```
