#!/usr/bin/env bash
# Launch the Phoenix server for the systemd service.
# Resolves the asdf-managed Erlang/Elixir from .tool-versions so PATH works
# under systemd (which has a minimal environment), loads .env, migrates, serves.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASDF_ROOT="${ASDF_DATA_DIR:-$HOME/.asdf}"
elixir_v="$(awk '/^elixir /{print $2}' .tool-versions)"
erlang_v="$(awk '/^erlang /{print $2}' .tool-versions)"
export PATH="$ASDF_ROOT/installs/elixir/$elixir_v/bin:$ASDF_ROOT/installs/erlang/$erlang_v/bin:$PATH"

# Secrets / API keys (gitignored).
set -a
[ -f .env ] && source .env
set +a

mix ecto.migrate || true
exec mix phx.server
