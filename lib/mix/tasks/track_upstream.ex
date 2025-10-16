defmodule Mix.Tasks.TrackUpstream do
  @shortdoc "Track upstream changes from Phoenix LiveView to LiveView Native"

  @moduledoc """
  Track and analyze upstream changes from Phoenix LiveView that need to be ported to LiveView Native.

  Uses OpenAI embeddings with cosine similarity for semantic code matching.
  All embeddings and analysis results are cached locally to avoid redundant API calls.

  ## Installation

  This tool can be used in two ways:

  ### 1. Local (within this project)

      mix track_upstream <args>

  ### 2. Global (installed as Mix archive)

  Install once from GitHub:

      mix archive.install github pinetops/live_view_native branch add-file-proximity-mix-task subdir script/track_upstream

  Or build and install locally:

      cd script/track_upstream
      mix do deps.get, archive.build, archive.install

  Then use from anywhere:

      mix track_upstream <args>

  To update:

      mix archive.install github pinetops/live_view_native branch add-file-proximity-mix-task subdir script/track_upstream --force

  To uninstall:

      mix archive.uninstall track_upstream

  ## Purpose

  This tool helps port changes from Phoenix LiveView to LiveView Native by:

  1. **Identifying analogous implementations** - Finding which LVN files correspond to PLV files
     to implement analogous solutions for all changes to the implementation in LiveView between
     the specified revisions

  2. **Translating tests** - Identifying which tests added to Phoenix LiveView can and should be
     translated to the LiveView Native project to maintain test coverage parity

  3. **Generating porting guides** - Creating detailed documentation of transformation rules and
     upstream changes to guide the implementation of analogous features

  The goal is to ensure LiveView Native maintains functional parity with Phoenix LiveView while
  adapting for native platforms instead of web browsers.

  ## Usage

      mix track_upstream <plv_start_rev> <plv_end_rev> <lvn_start_rev> [--upstream-dir <path>]

  ## Arguments

    * `plv_start_rev` - Upstream starting revision (e.g., v1.0.18)
    * `plv_end_rev` - Upstream ending revision (e.g., v1.1.14)
    * `lvn_start_rev` - Downstream revision to compare (e.g., commit hash)

  ## Options

    * `--upstream-dir <path>` - Path to upstream repository (default: current directory)

  ## Examples

      mix track_upstream v1.0.18 v1.1.14 5905fd1
      mix track_upstream v1.0.18 v1.1.14 5905fd1 --upstream-dir ../phoenix_live_view

  ## Requirements

    * `OPENAI_API_KEY` environment variable must be set
    * Current directory should be the downstream repository (or use appropriate paths)

  ## Output

    * Matched file pairs (existing)
    * Newly added Phoenix LiveView files categorized by relevance
    * Summary statistics
    * Individual file pair analyses in `translation_analyses/` directory
    * Global porting guide in `UPSTREAM_PORTING_GUIDE.md`

  ## Porting Constraints

  The analysis respects these constraints when identifying relevant changes:

  1. **LazyHTML vs Floki** - LiveView Native uses Floki for native markup parsing,
     but preserves LazyHTML for HTML fallback rendering in web browsers

  2. **CSS and JS Exclusions** - CSS and JavaScript related functionality is excluded
     as it's not applicable to native platforms

  3. **Module Namespacing** - Phoenix.LiveView → LiveViewNative transformations are
     tracked and documented for systematic porting
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # Parse arguments first to provide usage info without loading the script
    {plv_start_rev, plv_end_rev, lvn_start_rev, opts} = parse_args(args)
    upstream_dir = Keyword.get(opts, :upstream_dir, ".")

    # Ensure the script project is compiled
    # This allows the tool to work even if the main app doesn't compile
    script_path = Path.expand("script/track_upstream", File.cwd!())
    ensure_script_compiled(script_path)

    # Load the script
    Code.require_file("lib/track_upstream.ex", script_path)

    # Manually start dependencies needed by the script
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:crypto)
    {:ok, _} = Finch.start_link(name: Req.Finch)

    TrackUpstream.CLI.run(plv_start_rev, plv_end_rev, lvn_start_rev, analyze: true, upstream_dir: upstream_dir)
  end

  defp ensure_script_compiled(script_path) do
    # Change to script directory, compile, and return to original directory
    original_dir = File.cwd!()

    try do
      File.cd!(script_path)

      # Check if deps are installed
      unless File.dir?("deps") do
        IO.puts("Installing dependencies for track_upstream script...")
        System.cmd("mix", ["deps.get"], into: IO.stream(:stdio, :line))
      end

      # Compile the script project
      System.cmd("mix", ["compile"], into: IO.stream(:stdio, :line))
    after
      File.cd!(original_dir)
    end
  end

  defp parse_args(args) do
    {opts, remaining, _invalid} = OptionParser.parse(args,
      switches: [upstream_dir: :string],
      aliases: []
    )

    case remaining do
      [plv_start_rev, plv_end_rev, lvn_start_rev] ->
        upstream_dir = opts[:upstream_dir]

        final_opts = if upstream_dir, do: [upstream_dir: upstream_dir], else: []

        {plv_start_rev, plv_end_rev, lvn_start_rev, final_opts}

      _ ->
        IO.puts("Usage: mix track_upstream <plv_start_rev> <plv_end_rev> <lvn_start_rev> [--upstream-dir <path>]")
        IO.puts("Example: mix track_upstream v1.0.18 v1.1.14 some-commit-hash")
        IO.puts("")
        IO.puts("Options:")
        IO.puts("  --upstream-dir <path>    Path to upstream repository (default: current directory)")
        System.halt(1)
    end
  end
end
