import Config

config :exline, start_listener: false

# Keep capture/crash writes out of the real examples/ dirs.
config :exline,
  captures_dir: "tmp/test-captures",
  crash_dir: "tmp/test-crashes"

# The board must never read the developer's own ~/.claude/sessions: a real
# session reporting "busy" under an id a test happens to use would flake it.
# Tests that want self-reports pass :self_report_dir explicitly.
config :exline, self_report_dir: "tmp/test-no-self-reports"
