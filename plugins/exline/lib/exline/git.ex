defmodule Exline.Git do
  @moduledoc false

  require Logger

  @doc """
  Collect the line-2 git fields for `cwd` using two `git` invocations:
  `status --branch --porcelain=v2` (branch, ahead/behind, working-tree flags)
  and `rev-parse --show-toplevel --git-dir --git-common-dir` (repo name,
  worktree detection). Returns a map with nil fields when git is unavailable.
  """
  def gather(cwd) do
    parse(%{status: run_status(cwd), rev_parse: run_rev_parse(cwd)}, cwd)
  end

  @doc """
  Pure parse of the two command outputs (each the raw stdout string, or nil if
  the command failed) into the line-2 fields. Separated from `gather/1` so the
  parsing logic is testable without invoking git.
  """
  def parse(%{status: status, rev_parse: rev_parse}, cwd) do
    {root, worktree} = parse_rev_parse(rev_parse, cwd)
    {branch, ahead_behind, flags} = parse_status(status)

    %{root: root, worktree: worktree, branch: branch, status: flags, ahead_behind: ahead_behind}
  end

  defp parse_rev_parse(nil, cwd), do: {Path.basename(cwd), nil}

  defp parse_rev_parse(output, cwd) do
    case String.split(output, "\n", trim: true) do
      [toplevel, git_dir, common_dir | _] ->
        # git reports these relative to cwd or absolute inconsistently (e.g. from
        # a subdirectory git-dir is absolute but git-common-dir relative), so
        # resolve both before comparing — a linked worktree has them point to
        # genuinely different .git directories.
        linked? = Path.expand(git_dir, cwd) != Path.expand(common_dir, cwd)
        worktree = if linked?, do: "𖠰 " <> Path.basename(toplevel), else: nil
        {Path.basename(toplevel), worktree}

      _ ->
        {Path.basename(cwd), nil}
    end
  end

  defp parse_status(nil), do: {nil, nil, nil}

  defp parse_status(output) do
    lines = String.split(output, "\n", trim: true)
    {branch(lines), ahead_behind(lines), flags(lines)}
  end

  defp branch(lines) do
    case header(lines, "branch.head") do
      nil -> nil
      "(detached)" -> header(lines, "branch.oid") |> short_sha()
      name -> "⎇ " <> name
    end
  end

  defp short_sha(nil), do: nil
  defp short_sha(oid), do: "⎇ " <> String.slice(oid, 0, 7)

  defp ahead_behind(lines) do
    with ab when is_binary(ab) <- header(lines, "branch.ab"),
         [_, a, b] <- Regex.run(~r/\+(\d+)\s+-(\d+)/, ab) do
      format_ahead_behind(String.to_integer(a), String.to_integer(b))
    else
      _ -> nil
    end
  end

  # The header lines look like `# branch.head main`.
  defp header(lines, key) do
    prefix = "# " <> key <> " "

    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  defp flags(lines) do
    lines
    |> Enum.reduce(
      %{staged: false, unstaged: false, untracked: false, conflicts: false},
      &classify/2
    )
    |> format_flags()
  end

  # porcelain=v2 entry lines: `1`/`2` carry a two-char XY field (X=staged,
  # Y=unstaged; `.` means unmodified), `u` is an unmerged conflict, `?` untracked.
  defp classify(<<"1 ", x, y, _::binary>>, acc), do: apply_xy(x, y, acc)
  defp classify(<<"2 ", x, y, _::binary>>, acc), do: apply_xy(x, y, acc)
  defp classify(<<"u ", _::binary>>, acc), do: %{acc | conflicts: true}
  defp classify(<<"? ", _::binary>>, acc), do: %{acc | untracked: true}
  defp classify(_, acc), do: acc

  defp apply_xy(x, y, acc) do
    acc = if x != ?., do: %{acc | staged: true}, else: acc
    if y != ?., do: %{acc | unstaged: true}, else: acc
  end

  defp format_flags(f) do
    [{f.conflicts, "!"}, {f.staged, "+"}, {f.unstaged, "*"}, {f.untracked, "?"}]
    |> Enum.filter(fn {flag, _} -> flag end)
    |> Enum.map_join("", fn {_, sym} -> sym end)
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp format_ahead_behind(0, 0), do: nil
  defp format_ahead_behind(ahead, 0), do: "↑#{ahead}"
  defp format_ahead_behind(0, behind), do: "↓#{behind}"
  defp format_ahead_behind(ahead, behind), do: "↑#{ahead} ↓#{behind}"

  defp run_status(cwd), do: run(cwd, ["status", "--branch", "--porcelain=v2"])

  defp run_rev_parse(cwd),
    do: run(cwd, ["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"])

  defp run(cwd, args) do
    if File.dir?(cwd) do
      case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
        {output, 0} -> output
        {_, _} -> nil
      end
    else
      nil
    end
  rescue
    e ->
      Logger.warning("exline: git invocation failed: #{Exception.message(e)}")
      nil
  end
end
