defmodule Exline.SplitChain do
  @moduledoc """
  How many serial splits lead up to a session, for the status line's `split N×`
  mark.

  A serial split (the user's dotfiles `split.sh`) hands the work to a new
  Claude Code session and closes the old one, appending one JSON line per
  split to `~/.claude/split-chain.jsonl`:

      {"time": "…", "from": {"session": "<old id>", …}, "to": {"session": "<new id>", …}, …}

  The chain length for session S counts the records walked from the one whose
  `to.session` is S, back through each `from.session`, until no record names
  it. A missing or unreadable file, or no record for S, means no chain (`nil`).
  Lines that are not such a record are skipped.

  The status line asks on every render (about once a second per session), so
  the parsed file is kept in `:persistent_term` and re-read only when its
  mtime, size or inode changes; a render costs one `stat`.
  """

  @doc "Chain length for `session_id`, or `nil` when it did not come from a split."
  def count(session_id, path \\ default_path())

  def count(session_id, path) when is_binary(session_id) do
    case index(path) do
      nil -> nil
      links -> walk(links, session_id)
    end
  end

  def count(_session_id, _path), do: nil

  @doc "Where the split log is read from."
  def default_path, do: Path.join(System.user_home!(), ".claude/split-chain.jsonl")

  # Count records back from `session_id`. The visited set guards against a
  # cycle in a hand-edited log, which would otherwise loop forever.
  defp walk(links, session_id, count \\ 0, seen \\ MapSet.new()) do
    case Map.fetch(links, session_id) do
      {:ok, from} ->
        if MapSet.member?(seen, session_id),
          do: nilify(count),
          else: walk(links, from, count + 1, MapSet.put(seen, session_id))

      :error ->
        nilify(count)
    end
  end

  defp nilify(0), do: nil
  defp nilify(count), do: count

  # `to.session => from.session` for every usable record, cached per file
  # version. nil when the file cannot be read.
  defp index(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size, inode: inode}} ->
        version = {mtime, size, inode}

        case :persistent_term.get({__MODULE__, path}, nil) do
          {^version, links} ->
            links

          _stale_or_none ->
            links = parse(path)
            :persistent_term.put({__MODULE__, path}, {version, links})
            links
        end

      {:error, _reason} ->
        nil
    end
  end

  defp parse(path) do
    case File.read(path) do
      {:ok, raw} ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&link/1)
        |> Map.new()

      {:error, _reason} ->
        nil
    end
  end

  defp link(line) do
    case JSON.decode(line) do
      {:ok, %{"from" => %{"session" => from}, "to" => %{"session" => to}}}
      when is_binary(from) and is_binary(to) ->
        [{to, from}]

      _malformed ->
        []
    end
  end
end
