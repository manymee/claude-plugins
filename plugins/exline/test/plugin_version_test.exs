defmodule Exline.PluginVersionTest do
  use ExUnit.Case, async: true

  alias Exline.PluginVersion

  @moduletag :tmp_dir

  defp write_registry(dir, plugins) do
    path = Path.join(dir, "installed_plugins.json")
    File.write!(path, JSON.encode!(%{"version" => 2, "plugins" => plugins}))
    path
  end

  defp entry(version), do: [%{"scope" => "user", "version" => version}]

  test "running_version reports the app version" do
    assert PluginVersion.running_version() == Mix.Project.config()[:version]
  end

  test "installed_version finds exline under any marketplace name", %{tmp_dir: dir} do
    path = write_registry(dir, %{"exline@some-marketplace" => entry("9.9.9")})
    assert PluginVersion.installed_version(path) == "9.9.9"
  end

  test "installed_version is nil when exline is not installed", %{tmp_dir: dir} do
    path = write_registry(dir, %{"other@manymee" => entry("1.0.0")})
    assert PluginVersion.installed_version(path) == nil
  end

  test "installed_version is nil for a missing file" do
    assert PluginVersion.installed_version("/nonexistent/installed_plugins.json") == nil
  end

  test "installed_version is nil for malformed json", %{tmp_dir: dir} do
    path = Path.join(dir, "installed_plugins.json")
    File.write!(path, "not json")
    assert PluginVersion.installed_version(path) == nil
  end

  test "installed_version ignores an 'unknown' version", %{tmp_dir: dir} do
    path = write_registry(dir, %{"exline@manymee" => entry("unknown")})
    assert PluginVersion.installed_version(path) == nil
  end

  test "drift reports a version mismatch", %{tmp_dir: dir} do
    path = write_registry(dir, %{"exline@manymee" => entry("9.9.9")})
    running = PluginVersion.running_version()
    assert PluginVersion.drift(path) == {running, "9.9.9"}
  end

  test "drift is nil when versions match", %{tmp_dir: dir} do
    path = write_registry(dir, %{"exline@manymee" => entry(PluginVersion.running_version())})
    assert PluginVersion.drift(path) == nil
  end

  test "drift is nil when not installed as a plugin", %{tmp_dir: dir} do
    path = write_registry(dir, %{})
    assert PluginVersion.drift(path) == nil
  end

  test "plugin.json version stays in sync with mix.exs" do
    plugin_json = File.read!(".claude-plugin/plugin.json") |> JSON.decode!()
    assert plugin_json["version"] == Mix.Project.config()[:version]
  end
end
