import Config

config :exline, start_listener: false

# Keep capture/crash writes out of the real examples/ dirs.
config :exline,
  captures_dir: "tmp/test-captures",
  crash_dir: "tmp/test-crashes"
