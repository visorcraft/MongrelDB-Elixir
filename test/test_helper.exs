# Exclude live tests by default; they require a running mongreldb-server. CI
# enables them with `mix test --include skip_without_server` after booting the
# daemon. Even when included, each live test self-skips if the server is not
# actually reachable.
ExUnit.start(exclude: [:skip_without_server])
