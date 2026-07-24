defmodule Exline.GitTest do
  use ExUnit.Case, async: true

  alias Exline.Git

  @cwd "/tmp/exline-test/repo"

  # Sample `git rev-parse --show-toplevel --git-dir --git-common-dir` output.
  defp rev_parse(toplevel \\ "/tmp/exline-test/repo", git_dir \\ ".git", common \\ ".git"),
    do: Enum.join([toplevel, git_dir, common], "\n")

  describe "parse/2 — branch" do
    test "shows the current branch name" do
      status = """
      # branch.oid 1111111111111111111111111111111111111111
      # branch.head main
      """

      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.branch == "⎇ main"
    end

    test "falls back to a short SHA when detached" do
      status = """
      # branch.oid abcdef1234567890000000000000000000000000
      # branch.head (detached)
      """

      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.branch == "⎇ abcdef1"
    end
  end

  describe "parse/2 — ahead/behind" do
    test "renders ahead and behind from branch.ab" do
      status = """
      # branch.head main
      # branch.upstream origin/main
      # branch.ab +2 -3
      """

      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.ahead_behind == "↑2 ↓3"
    end

    test "is nil when there is no upstream (no branch.ab line)" do
      status = "# branch.head main\n"
      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.ahead_behind == nil
    end

    test "is nil when level with upstream" do
      status = "# branch.head main\n# branch.ab +0 -0\n"
      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.ahead_behind == nil
    end
  end

  describe "parse/2 — status flags" do
    test "combines conflict, staged, unstaged, and untracked in fixed order" do
      status = """
      # branch.head main
      1 M. N... 100644 100644 100644 aaa bbb staged.txt
      1 .M N... 100644 100644 100644 aaa bbb unstaged.txt
      u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt
      ? untracked.txt
      """

      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.status == "!+*?"
    end

    test "is nil for a clean tree" do
      status = "# branch.head main\n"
      g = Git.parse(%{status: status, rev_parse: rev_parse()}, @cwd)
      assert g.status == nil
    end
  end

  describe "parse/2 — root and worktree" do
    test "root is the basename of the toplevel" do
      g = Git.parse(%{status: "# branch.head main\n", rev_parse: rev_parse("/a/b/dotfiles")}, @cwd)
      assert g.root == "dotfiles"
    end

    test "worktree is nil in the main checkout (git-dir == git-common-dir)" do
      g = Git.parse(%{status: "# branch.head main\n", rev_parse: rev_parse()}, @cwd)
      assert g.worktree == nil
    end

    test "worktree is labelled when git-dir differs from git-common-dir" do
      rp = rev_parse("/repo/wt-feature", "/repo/.git/worktrees/wt-feature", "/repo/.git")
      g = Git.parse(%{status: "# branch.head main\n", rev_parse: rp}, @cwd)
      assert g.worktree == "𖠰 wt-feature"
    end

    test "worktree is nil from a subdirectory of the main checkout" do
      # From a subdir, git reports git-dir absolute but git-common-dir relative;
      # they resolve to the same .git, so this is not a linked worktree.
      rp = rev_parse("/u/repo", "/u/repo/.git", "../../.git")
      g = Git.parse(%{status: "# branch.head main\n", rev_parse: rp}, "/u/repo/sub/dir")
      assert g.worktree == nil
    end
  end

  describe "parse/2 — failures fall back" do
    test "uses basename of cwd for root and nils the rest when both commands failed" do
      g = Git.parse(%{status: nil, rev_parse: nil}, "/tmp/exline-test-cwd/dotfiles")
      assert g == %{root: "dotfiles", worktree: nil, branch: nil, status: nil, ahead_behind: nil}
    end
  end

  describe "gather/1 — against a real repo" do
    @tag :tmp_dir
    test "reports branch, root, and a dirty flag", %{tmp_dir: dir} do
      {_, 0} = System.cmd("git", ["init", "-b", "main", "."], cd: dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@t"], cd: dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
      File.write!(Path.join(dir, "a.txt"), "hi")
      {_, 0} = System.cmd("git", ["add", "a.txt"], cd: dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: dir)
      File.write!(Path.join(dir, "b.txt"), "new")

      g = Git.gather(dir)
      assert g.branch == "⎇ main"
      assert g.root == Path.basename(dir)
      assert g.status == "?"
      assert g.worktree == nil
    end

    test "falls back to basename when cwd is not a git repo" do
      g = Git.gather("/tmp/exline-test-cwd/dotfiles")
      assert g == %{root: "dotfiles", worktree: nil, branch: nil, status: nil, ahead_behind: nil}
    end

    @tag :tmp_dir
    test "a subdirectory of the main checkout is not reported as a worktree", %{tmp_dir: dir} do
      {_, 0} = System.cmd("git", ["init", "-b", "main", "."], cd: dir, stderr_to_stdout: true)
      sub = Path.join(dir, "nested/deep")
      File.mkdir_p!(sub)

      g = Git.gather(sub)
      assert g.worktree == nil
      assert g.root == Path.basename(dir)
    end
  end
end
