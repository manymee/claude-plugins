import Config

# Prod (the launchd/plugin daemon) owns the canonical socket; every other env
# defaults to the dev socket so `iex -S mix` can run alongside the live daemon
# without stealing its socket. The client prefers the dev socket when present.
default_socket =
  if config_env() == :prod, do: "/tmp/exline.sock", else: "/tmp/exline-dev.sock"

config :exline, socket_path: System.get_env("EXLINE_SOCKET", default_socket)
