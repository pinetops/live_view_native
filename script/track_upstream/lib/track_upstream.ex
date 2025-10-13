defmodule TrackUpstream do
  @moduledoc """
  Upstream changes tracker for matching Phoenix LiveView and LiveView Native files.

  Uses OpenAI embeddings with cosine similarity for semantic code matching.
  All embeddings and analysis results are cached locally to avoid redundant API calls.
  """

  # ============================================================================
  # CONFIGURATION MODULE
  # ============================================================================

  defmodule Config do
    @moduledoc """
    Configuration and constants for upstream change tracking.
    """

    @porting_constraints """
    IMPORTANT CONSTRAINTS when porting from Phoenix LiveView to LiveView Native:

    1. **LazyHTML vs Floki:**
       - LiveView Native uses Floki for parsing native markup (our primary use case)
       - LazyHTML is Phoenix LiveView's HTML parser and is NOT compatible with native markup
       - HOWEVER: LiveViewNative also supports HTML fallback rendering for web browsers
       - Therefore: LazyHTML-based code MAY be included if it's specifically for HTML fallback testing
       - When in doubt: Prefer Floki for native markup, preserve LazyHTML only for HTML fallback paths

    2. **CSS and JS Exclusions:**
       - CSS-related functionality should NOT be translated (not applicable to native platforms)
       - JavaScript-related functionality should NOT be translated (not applicable to native platforms)
       - This includes: style attributes, CSS selectors (unless used for general querying), JS interop, etc.

    3. **Module Namespacing:**
       - Phoenix.LiveView → LiveViewNative
       - Phoenix.LiveViewTest → LiveViewNativeTest
       - HTML-specific terms → Native-agnostic or native-specific terms
    """

    @cache_dirs %{
      embeddings: ".track_changes_cache/embeddings",
      similarity: ".track_changes_cache/similarity",
      verification: ".track_changes_cache/verification",
      git_content: ".track_changes_cache/git_content",
      modules: ".track_changes_cache/modules"
    }

    @openai_config %{
      embedding_model: "text-embedding-3-small",
      chat_model: "gpt-4o-mini",
      analysis_model: "gpt-4o",
      max_content_length: 20_000,
      timeout: 120_000
    }

    @analysis_config %{
      similarity_threshold: 0.70,
      concurrency: System.schedulers_online() * 2
    }

    def porting_constraints, do: @porting_constraints
    def cache_dirs, do: @cache_dirs
    def openai_config, do: @openai_config
    def analysis_config, do: @analysis_config

    @doc "Ensure all cache directories exist"
    def ensure_cache_dirs! do
      Enum.each(@cache_dirs, fn {_name, dir} ->
        File.mkdir_p!(dir)
      end)
    end

    @doc "Validate configuration is ready"
    def validate! do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY environment variable not set"
      ensure_cache_dirs!()
      :ok
    end
  end

  # ============================================================================
  # GIT OPERATIONS MODULE
  # ============================================================================

  defmodule Git do
    @moduledoc """
    Git operations for reading file lists and content from repositories.
    """

    @doc """
    Get list of Elixir files from a git repository at a specific revision.
    Filters to only include lib/ and test/ directories, excluding test/e2e/.
    """
    def get_elixir_files(dir, rev) do
      {output, 0} = System.cmd("git", ["-C", dir, "ls-tree", "-r", "--name-only", rev])

      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/\.(ex|exs)$/))
      |> Enum.filter(&String.match?(&1, ~r/^(lib|test)\//))
      |> Enum.reject(&String.starts_with?(&1, "test/e2e/"))
    end

    @doc """
    Get file content from a git repository at a specific revision.
    Results are cached to avoid redundant git operations.
    """
    def get_file_content(dir, rev, file) do
      cache_dir = Config.cache_dirs().git_content
      File.mkdir_p!(cache_dir)

      # Create cache key from dir, rev, and file
      cache_key = :crypto.hash(:sha256, "#{dir}:#{rev}:#{file}") |> Base.encode16(case: :lower)
      cache_file = Path.join(cache_dir, "#{cache_key}.txt")

      # Check cache first
      if File.exists?(cache_file) do
        content = File.read!(cache_file)
        {:ok, content}
      else
        case System.cmd("git", ["-C", dir, "show", "#{rev}:#{file}"], stderr_to_stdout: true) do
          {content, 0} ->
            File.write!(cache_file, content)
            {:ok, content}

          _ ->
            :error
        end
      end
    end

    @doc """
    Check if a file has changes between two revisions in a git repository.
    """
    def has_changes?(dir, start_rev, end_rev, file) do
      case System.cmd("git", ["-C", dir, "diff", "#{start_rev}..#{end_rev}", "--", file],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          # If diff output is not empty, there are changes
          String.trim(output) != ""

        _ ->
          # If git diff fails, assume no changes
          false
      end
    end
  end

  # ============================================================================
  # CACHE UTILITIES MODULE
  # ============================================================================

  defmodule Cache do
    @moduledoc """
    Generic caching utilities for JSON data.
    """

    @doc """
    Get cached value or compute it if not in cache.
    Handles corrupted/empty cache files by treating them as cache misses.
    """
    def get_or_compute(cache_type, key, compute_fn) do
      cache_dir = Config.cache_dirs()[cache_type]
      File.mkdir_p!(cache_dir)

      cache_file = Path.join(cache_dir, "#{key}.json")

      if File.exists?(cache_file) do
        case File.read(cache_file) do
          {:ok, ""} ->
            # Empty file, treat as cache miss
            compute_and_cache(cache_file, compute_fn)

          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, result} ->
                result

              {:error, _} ->
                # Corrupted cache, recompute
                compute_and_cache(cache_file, compute_fn)
            end

          {:error, _} ->
            # Can't read file, recompute
            compute_and_cache(cache_file, compute_fn)
        end
      else
        compute_and_cache(cache_file, compute_fn)
      end
    end

    defp compute_and_cache(cache_file, compute_fn) do
      result = compute_fn.()
      File.write!(cache_file, Jason.encode!(result))
      result
    end

    @doc """
    Get cached text content or compute it if not in cache.
    """
    def get_or_compute_text(cache_type, key, compute_fn) do
      cache_dir = Config.cache_dirs()[cache_type]
      File.mkdir_p!(cache_dir)

      cache_file = Path.join(cache_dir, "#{key}.txt")

      if File.exists?(cache_file) do
        File.read!(cache_file)
      else
        result = compute_fn.()
        File.write!(cache_file, result)
        result
      end
    end
  end

  # ============================================================================
  # OPENAI EMBEDDINGS MODULE
  # ============================================================================

  defmodule OpenAI.Embeddings do
    @moduledoc """
    OpenAI embedding operations for semantic similarity.
    """

    alias TrackUpstream.{Cache, Config}

    @doc """
    Calculate embedding similarity between two pieces of content.
    Uses cosine similarity between OpenAI embeddings.
    """
    def similarity(content1, content2) do
      # Create cache key from both contents
      cache_key = :crypto.hash(:sha256, content1 <> content2) |> Base.encode16(case: :lower)

      Cache.get_or_compute(:similarity, cache_key, fn ->
        # Get embeddings (with caching)
        embedding1 = get_embedding(content1)
        embedding2 = get_embedding(content2)

        # Calculate cosine similarity
        cosine_similarity(embedding1, embedding2)
      end)
    end

    @doc """
    Get embedding for content (with caching).
    """
    def get_embedding(content) do
      # Create cache key from content hash
      cache_key = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      Cache.get_or_compute(:embeddings, cache_key, fn ->
        fetch_embedding_from_openai(content)
      end)
    end

    # Private functions

    defp fetch_embedding_from_openai(content) do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY environment variable not set"

      config = Config.openai_config()

      # Truncate if too long
      content =
        if String.length(content) > config.max_content_length do
          String.slice(content, 0, config.max_content_length)
        else
          content
        end

      response =
        Req.post!(
          "https://api.openai.com/v1/embeddings",
          json: %{
            model: config.embedding_model,
            input: content
          },
          headers: [{"Authorization", "Bearer #{api_key}"}],
          retry: :transient
        )

      case response.status do
        200 ->
          %{"data" => [%{"embedding" => embedding}]} = response.body
          embedding

        _ ->
          raise "OpenAI API error: #{inspect(response)}"
      end
    end

    defp cosine_similarity(vec1, vec2) do
      dot_product =
        Enum.zip(vec1, vec2)
        |> Enum.map(fn {a, b} -> a * b end)
        |> Enum.sum()

      magnitude1 = :math.sqrt(Enum.map(vec1, fn x -> x * x end) |> Enum.sum())
      magnitude2 = :math.sqrt(Enum.map(vec2, fn x -> x * x end) |> Enum.sum())

      if magnitude1 > 0 and magnitude2 > 0 do
        dot_product / (magnitude1 * magnitude2)
      else
        0.0
      end
    end
  end

  # ============================================================================
  # OPENAI CHAT MODULE
  # ============================================================================

  defmodule OpenAI.Chat do
    @moduledoc """
    OpenAI chat operations for LLM-based verification and analysis.
    """

    alias TrackUpstream.{Cache, Config}

    @doc """
    Verify if one file is a translation/port of another using LLM.
    """
    def verify_translation(plv_file, plv_content, lvn_file, lvn_content) do
      # Create cache key from both file contents
      cache_key =
        :crypto.hash(:sha256, plv_content <> lvn_content) |> Base.encode16(case: :lower)

      Cache.get_or_compute(:verification, cache_key, fn ->
        ask_llm_verification(plv_file, plv_content, lvn_file, lvn_content)
      end)
    end

    @doc """
    Extract module names defined in a lib file using LLM.
    """
    def extract_defined_modules(file_path, content) do
      cache_key = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      Cache.get_or_compute(:modules, "defined_#{cache_key}", fn ->
        query_modules(file_path, content, :defined)
      end)
    end

    @doc """
    Get modules tested in a test file using LLM.
    """
    def get_tested_modules(file_path, content) do
      cache_key = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      Cache.get_or_compute(:modules, "tested_#{cache_key}", fn ->
        query_modules(file_path, content, :tested)
      end)
    end

    @doc """
    Generate a description of a file for LLM consumption.
    """
    def generate_file_description(file_path, content) do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY not set"

      config = Config.openai_config()

      # Truncate if needed
      truncated_content =
        if String.length(content) > config.max_content_length do
          String.slice(content, 0, config.max_content_length) <> "\n... [truncated]"
        else
          content
        end

      prompt = """
      Analyze this newly added Phoenix LiveView file and provide a concise description that helps determine when this file is relevant for porting to LiveView Native.

      **File:** #{file_path}

      **Content:**
      ```elixir
      #{truncated_content}
      ```

      **Provide:**
      1. **Purpose:** What does this file do? (1-2 sentences)
      2. **Key exports:** Main functions, modules, or macros defined
      3. **Dependencies:** Notable dependencies or integrations with other LiveView components
      4. **Relevance for LVN:** When would this be needed in LiveView Native? (e.g., "only if implementing X feature", "core testing infrastructure", "web-specific, likely not needed")

      Keep the description concise and factual. Format as markdown.
      """

      response =
        Req.post!(
          "https://api.openai.com/v1/chat/completions",
          json: %{
            model: config.chat_model,
            messages: [%{role: "user", content: prompt}],
            temperature: 0
          },
          headers: [{"Authorization", "Bearer #{api_key}"}],
          retry: :transient,
          receive_timeout: 60_000
        )

      case response.status do
        200 ->
          response.body["choices"] |> List.first() |> Map.get("message") |> Map.get("content")

        _ ->
          "_Could not generate description (API error)_"
      end
    end

    @doc """
    Call OpenAI to perform analysis using the file-pair-analyzer agent.
    """
    def call_analysis_agent(prompt) do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY not set"

      config = Config.openai_config()

      # Read the file-pair-analyzer agent instructions
      agent_instructions = """
      TASK: Please upgrade the current version of LiveView Native to incorporate recent changes to Phoenix LiveView, of which it is a derivative.

      #{Config.porting_constraints()}

      CONTEXT:
      - BASELINE TRANSFORMATION: PLV start → LVN start shows how the original code was adapted
      - UPSTREAM DELTA: PLV start → PLV end shows what changed upstream that needs porting
      - YOUR JOB: Document the baseline transformation to guide applying the upstream delta

      Your task:
      1. Analyze DIFF 2 (PLV start → LVN start): Identify FILE-GLOBAL transformation rules
      2. Document these rules - they show HOW to adapt PLV code to LVN
      3. Analyze DIFF 1 (PLV start → PLV end): Show upstream changes in LLM-friendly format
      4. DO NOT LOSE INFORMATION - all changes must be accounted for

      Output format:

      ## FILE-GLOBAL TRANSFORMATION RULES (PLV start → LVN start)

      These rules describe how this file was adapted from PLV to LVN. Use these patterns when porting upstream changes.

      For each rule:
      - Rule name and pattern (e.g., "Module namespace: Phoenix.LiveView.X → LiveViewNative.X")
      - Number of applications
      - 1-2 concrete examples showing the transformation

      ## BASELINE TRANSFORMATION DETAILS (PLV start → LVN start)

      ### Mechanical Changes
      For each location where rules apply:
      - Location (function names or line ranges)
      - Which rules apply
      - Count

      ### Unique Semantic Changes
      For changes NOT covered by rules:
      - Description
      - Location
      - Before (PLV start) / After (LVN start) code
      - Why this adaptation was needed

      ## UPSTREAM DELTA (PLV start → PLV end)

      **These are the changes that need to be ported to LVN.**

      Format in an LLM-friendly way:
      - If no changes: state "No upstream changes"
      - If changes exist: show each change as:
        * Location (function/line)
        * What changed (before → after)
        * Type of change (new feature, bug fix, refactor, etc.)

      ## SUMMARY

      - Baseline transformation rules: [count]
      - Upstream changes to port: [count]
      - Key observations: [factual observations about applying transformation rules to the upstream changes]
      """

      response =
        Req.post!(
          "https://api.openai.com/v1/chat/completions",
          json: %{
            model: config.analysis_model,
            messages: [
              %{role: "system", content: agent_instructions},
              %{role: "user", content: prompt}
            ],
            temperature: 0
          },
          headers: [{"Authorization", "Bearer #{api_key}"}],
          retry: :transient,
          receive_timeout: config.timeout
        )

      case response.status do
        200 ->
          response.body["choices"] |> List.first() |> Map.get("message") |> Map.get("content")

        _ ->
          "Error: OpenAI API call failed - #{inspect(response)}"
      end
    end

    # Private functions

    defp ask_llm_verification(plv_file, plv_content, lvn_file, lvn_content) do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY environment variable not set"

      config = Config.openai_config()

      # Truncate if needed
      plv_content =
        if String.length(plv_content) > config.max_content_length do
          String.slice(plv_content, 0, config.max_content_length) <> "\n... [truncated]"
        else
          plv_content
        end

      lvn_content =
        if String.length(lvn_content) > config.max_content_length do
          String.slice(lvn_content, 0, config.max_content_length) <> "\n... [truncated]"
        else
          lvn_content
        end

      # Determine file types more precisely
      get_file_type = fn file ->
        cond do
          String.starts_with?(file, "lib/") -> :lib
          String.ends_with?(file, "_test.exs") -> :test
          String.starts_with?(file, "test/support/") -> :support
          String.starts_with?(file, "test/") -> :support
          true -> :unknown
        end
      end

      plv_type = get_file_type.(plv_file)
      lvn_type = get_file_type.(lvn_file)

      # If file types don't match, it's not a translation
      if plv_type != lvn_type do
        %{
          "is_translation" => false,
          "confidence" => "high",
          "reason" => "File types don't match: PLV is #{plv_type}, LVN is #{lvn_type}"
        }
      else
        prompt = """
        You are analyzing two Elixir source files to determine if the LiveView Native file was created by copying and adapting the Phoenix LiveView file.

        Context: LiveView Native was built by copying Phoenix LiveView files and modifying them to support native platforms. A "translation" means the LVN file was literally created from the PLV file as its source, with systematic changes like Phoenix.LiveView → LiveViewNative.

        Phoenix LiveView file:
        ```elixir
        #{plv_content}
        ```

        LiveView Native file:
        ```elixir
        #{lvn_content}
        ```

        To determine if this is a translation, answer these questions:

        1. What is the PRIMARY PURPOSE of the PLV file? (e.g., "tests routing behavior", "implements server channel", "defines component DSL")
        2. What is the PRIMARY PURPOSE of the LVN file?
        3. Are these purposes IDENTICAL? (not just similar domain, but the EXACT SAME thing)

        A TRUE translation means:
        - Both files serve the EXACT SAME PRIMARY PURPOSE
        - The overall architecture and flow are nearly IDENTICAL
        - The function signatures and control flow match closely
        - Only implementation DETAILS differ (e.g., HTML vs native, Phoenix.LiveView → LiveViewNative)
        - It's the SAME BLUEPRINT with platform-specific adaptations

        NOT a translation (even if high similarity):
        - Different primary purposes (e.g., routing tests vs integration tests, server vs client)
        - Similar domain but different features (e.g., both test LiveView but test different aspects)
        - Both use similar patterns but for different goals

        Answer with a JSON object:
        {
          "is_translation": true/false,
          "confidence": "high"/"medium"/"low",
          "reason": "brief explanation mentioning what each file does"
        }
        """

        response =
          Req.post!(
            "https://api.openai.com/v1/chat/completions",
            json: %{
              model: config.chat_model,
              messages: [%{role: "user", content: prompt}],
              response_format: %{type: "json_object"},
              temperature: 0
            },
            headers: [{"Authorization", "Bearer #{api_key}"}],
            retry: :transient
          )

        case response.status do
          200 ->
            content =
              response.body["choices"] |> List.first() |> Map.get("message") |> Map.get("content")

            Jason.decode!(content)

          _ ->
            %{"is_translation" => false, "confidence" => "low", "reason" => "API error"}
        end
      end
    end

    defp query_modules(file_path, content, mode) do
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY not set"

      config = Config.openai_config()

      truncated_content =
        if String.length(content) > config.max_content_length do
          String.slice(content, 0, config.max_content_length) <> "\n... [truncated]"
        else
          content
        end

      prompt =
        case mode do
          :defined ->
            """
            List all Elixir module names defined in this file (#{file_path}).
            Only return module names that are defined with 'defmodule'.

            ```elixir
            #{truncated_content}
            ```

            Return a JSON array of module names (as strings):
            ["ModuleName1", "ModuleName2"]
            """

          :tested ->
            """
            List all Elixir module names that are being tested in this test file (#{file_path}).
            Look for modules that are imported, aliased, or directly referenced in tests.

            ```elixir
            #{truncated_content}
            ```

            Return a JSON array of module names (as strings):
            ["ModuleName1", "ModuleName2"]
            """
        end

      response =
        Req.post!(
          "https://api.openai.com/v1/chat/completions",
          json: %{
            model: config.chat_model,
            messages: [%{role: "user", content: prompt}],
            response_format: %{type: "json_object"},
            temperature: 0
          },
          headers: [{"Authorization", "Bearer #{api_key}"}],
          retry: :transient
        )

      case response.status do
        200 ->
          content =
            response.body["choices"] |> List.first() |> Map.get("message") |> Map.get("content")

          decoded = Jason.decode!(content)

          # Handle both {"modules": [...]} and direct array
          case decoded do
            %{"modules" => modules} when is_list(modules) -> modules
            modules when is_list(modules) -> modules
            _ -> []
          end

        _ ->
          []
      end
    end
  end

  # ============================================================================
  # FILE MATCHER MODULE
  # ============================================================================

  defmodule FileMatcher do
    @moduledoc """
    File matching logic using semantic similarity.
    """

    alias TrackUpstream.{Config, Git, OpenAI}

    @doc """
    Find the closest matching LVN file for a given PLV file.
    Returns {plv_file, best_match, similarity, verification} or nil.
    """
    def find_closest_match(plv_file, plv_dir, plv_rev, lvn_files, lvn_dir, lvn_rev) do
      case Git.get_file_content(plv_dir, plv_rev, plv_file) do
        {:ok, plv_content} when byte_size(plv_content) > 0 ->
          # Compare with all LVN files using embeddings
          {best_match, best_similarity, best_lvn_content} =
            lvn_files
            |> Enum.reduce({nil, 0.0, nil}, fn lvn_file, {best_file, best_sim, best_content} ->
              case Git.get_file_content(lvn_dir, lvn_rev, lvn_file) do
                {:ok, lvn_content} when byte_size(lvn_content) > 0 ->
                  # Use embedding-based cosine similarity
                  similarity = OpenAI.Embeddings.similarity(plv_content, lvn_content)

                  if similarity > best_sim do
                    {lvn_file, similarity, lvn_content}
                  else
                    {best_file, best_sim, best_content}
                  end

                _ ->
                  {best_file, best_sim, best_content}
              end
            end)

          if best_match do
            # For matches >70%, verify with LLM
            threshold = Config.analysis_config().similarity_threshold

            verification =
              if best_similarity > threshold do
                IO.write(".")
                OpenAI.Chat.verify_translation(plv_file, plv_content, best_match, best_lvn_content)
              else
                nil
              end

            {plv_file, best_match, best_similarity, verification}
          else
            nil
          end

        _ ->
          nil
      end
    end

    @doc """
    Get all modules defined in lib files using LLM.
    """
    def get_modules_from_lib_files(dir, rev, lib_files) do
      concurrency = Config.analysis_config().concurrency

      lib_files
      |> Task.async_stream(
        fn lib_file ->
          case Git.get_file_content(dir, rev, lib_file) do
            {:ok, content} ->
              modules = OpenAI.Chat.extract_defined_modules(lib_file, content)
              IO.write(".")
              modules

            _ ->
              []
          end
        end,
        timeout: :infinity,
        max_concurrency: concurrency
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> List.flatten()
      |> MapSet.new()
    end
  end

  # ============================================================================
  # FILE PAIR ANALYZER MODULE
  # ============================================================================

  defmodule FilePairAnalyzer do
    @moduledoc """
    Generate diffs for a file pair to show upstream changes and baseline transformations.
    """

    alias TrackUpstream.Git

    @doc """
    Generate formatted diff output for a file pair.
    Returns a string containing three diffs:
    1. PLV start → PLV end (upstream changes)
    2. PLV start → LVN start (baseline transformation)
    3. LVN start → workdir (work in progress)
    """
    def analyze_file_pair(plv_start_rev, plv_end_rev, lvn_start_rev, plv_file, lvn_file) do
      plv_dir = "../phoenix_live_view"
      lvn_dir = "."

      header = """
      #{"=" |> String.duplicate(80)}
      FILE PAIR ANALYSIS
      #{"=" |> String.duplicate(80)}
      PLV: #{plv_file}
      LVN: #{lvn_file}

      """

      diff1 = """
      ### DIFF 1: Phoenix LiveView #{plv_start_rev}..#{plv_end_rev} ###
      #{generate_repo_diff(plv_dir, plv_start_rev, plv_end_rev, plv_file)}

      """

      diff2 = """
      ### DIFF 2: PLV #{plv_start_rev} -> LVN #{lvn_start_rev} ###
      #{generate_cross_repo_diff(plv_dir, plv_start_rev, plv_file, lvn_dir, lvn_start_rev, lvn_file)}

      """

      diff3 = """
      ### DIFF 3: LVN #{lvn_start_rev} -> workdir ###
      #{generate_workdir_diff(lvn_dir, lvn_start_rev, lvn_file)}

      """

      footer = "#{String.duplicate("=", 80)}\n"

      header <> diff1 <> diff2 <> diff3 <> footer
    end

    # Private functions

    defp generate_repo_diff(dir, start_rev, end_rev, file) do
      case System.cmd("git", ["-C", dir, "diff", "#{start_rev}..#{end_rev}", "--", file],
             stderr_to_stdout: true
           ) do
        {output, 0} when byte_size(output) > 0 ->
          output

        {_, 0} ->
          "(no changes)"

        {error, _} ->
          "Error: #{error}"
      end
    end

    defp generate_cross_repo_diff(plv_dir, plv_rev, plv_file, lvn_dir, lvn_rev, lvn_file) do
      with {:ok, plv_content} <- Git.get_file_content(plv_dir, plv_rev, plv_file),
           {:ok, lvn_content} <- Git.get_file_content(lvn_dir, lvn_rev, lvn_file) do
        # Create temp files
        plv_temp = System.tmp_dir!() |> Path.join("plv_#{Path.basename(plv_file)}")
        lvn_temp = System.tmp_dir!() |> Path.join("lvn_#{Path.basename(lvn_file)}")

        File.write!(plv_temp, plv_content)
        File.write!(lvn_temp, lvn_content)

        # Generate diff
        result =
          case System.cmd("diff", ["-u", plv_temp, lvn_temp], stderr_to_stdout: true) do
            {output, exit_code} when exit_code in [0, 1] ->
              # Replace temp file paths with meaningful names
              output =
                output
                |> String.replace(plv_temp, "PLV:#{plv_file}")
                |> String.replace(lvn_temp, "LVN:#{lvn_file}")

              if byte_size(output) > 0 do
                output
              else
                "(identical)"
              end

            {error, _} ->
              "Error: #{error}"
          end

        # Clean up temp files
        File.rm(plv_temp)
        File.rm(lvn_temp)

        result
      else
        _ -> "Error: Could not read file contents"
      end
    end

    defp generate_workdir_diff(dir, rev, file) do
      case System.cmd("git", ["-C", dir, "diff", rev, "--", file], stderr_to_stdout: true) do
        {output, 0} when byte_size(output) > 0 ->
          output

        {_, 0} ->
          "(no changes)"

        {error, _} ->
          "Error: #{error}"
      end
    end
  end

  # ============================================================================
  # ANALYSIS MODULE
  # ============================================================================

  defmodule Analysis do
    @moduledoc """
    Detailed analysis orchestration for file pairs.
    """

    alias TrackUpstream.{FilePairAnalyzer, Git, GuideBuilder, OpenAI}

    @doc """
    Run detailed analysis on all file pairs using GPT-4o.
    """
    def run_detailed_analysis(
          plv_start_rev,
          plv_end_rev,
          lvn_start_rev,
          file_pairs,
          newly_added_files
        ) do
      plv_dir = "../phoenix_live_view"

      # Filter to only pairs where PLV source has changed
      IO.puts(
        "Checking which PLV files have changed between #{plv_start_rev} and #{plv_end_rev}..."
      )

      changed_pairs =
        file_pairs
        |> Enum.filter(fn {plv_file, _lvn_file, _sim, _ver} ->
          Git.has_changes?(plv_dir, plv_start_rev, plv_end_rev, plv_file)
        end)

      filtered_count = length(file_pairs) - length(changed_pairs)

      IO.puts("Found #{length(changed_pairs)} file pairs with upstream changes")

      if filtered_count > 0 do
        IO.puts("Skipped #{filtered_count} pairs with no upstream changes")
      end

      IO.puts("")

      if Enum.empty?(changed_pairs) do
        IO.puts("No file pairs have upstream changes to analyze.")
        :ok
      else
        IO.puts("Analyzing #{length(changed_pairs)} file pairs with GPT-4o...")
        IO.puts("")

        # Create output directory
        output_dir = "translation_analyses"
        File.mkdir_p!(output_dir)

        # Analyze each file pair
        analyses =
          changed_pairs
          |> Enum.with_index(1)
          |> Enum.map(fn {{plv_file, lvn_file, similarity, _verification}, idx} ->
            IO.puts(
              "[#{idx}/#{length(changed_pairs)}] Analyzing: #{plv_file} -> #{lvn_file}"
            )

            # Get the actual diffs
            diff_output =
              FilePairAnalyzer.analyze_file_pair(
                plv_start_rev,
                plv_end_rev,
                lvn_start_rev,
                plv_file,
                lvn_file
              )

            # Call analysis agent
            prompt = """
            Analyze this PLV/LVN file pair to document the baseline transformation and upstream delta:

            **File Pair:**
            - PLV file: #{plv_file}
            - LVN file: #{lvn_file}
            - Similarity: #{Float.round(similarity * 100, 2)}%

            **Revisions:**
            - PLV start: #{plv_start_rev}
            - PLV end: #{plv_end_rev}
            - LVN start: #{lvn_start_rev}

            **Diffs:**

            The output below contains three diffs:
            1. DIFF 1 (PLV #{plv_start_rev} → #{plv_end_rev}): UPSTREAM DELTA - changes that need porting
            2. DIFF 2 (PLV #{plv_start_rev} → LVN #{lvn_start_rev}): BASELINE TRANSFORMATION - how code was adapted
            3. DIFF 3 (LVN #{lvn_start_rev} → working dir): Work in progress (if any)

            #{diff_output}

            **Your task:**
            Analyze these diffs and provide a structured analysis showing:
            1. How the code was transformed from PLV to LVN (DIFF 2) - extract transformation rules
            2. What changed upstream in PLV (DIFF 1) - format for LLM consumption
            3. Guidance on applying the transformation rules to the upstream changes
            """

            analysis = OpenAI.Chat.call_analysis_agent(prompt)

            # Save individual analysis
            safe_filename = String.replace(plv_file, "/", "_")
            File.write!(Path.join(output_dir, "#{safe_filename}.md"), analysis)

            {plv_file, lvn_file, similarity, analysis}
          end)

        IO.puts("")
        IO.puts("Individual analyses saved to #{output_dir}/")
        IO.puts("")

        # Build global translation guide
        IO.puts("Building global translation guide...")

        global_guide =
          GuideBuilder.build_global_guide(
            analyses,
            plv_start_rev,
            plv_end_rev,
            lvn_start_rev,
            newly_added_files,
            plv_dir
          )

        # Save global guide
        guide_path = "UPSTREAM_PORTING_GUIDE.md"
        File.write!(guide_path, global_guide)

        IO.puts("")
        IO.puts("=" |> String.duplicate(80))
        IO.puts("Analysis complete!")
        IO.puts("=" |> String.duplicate(80))
        IO.puts("Individual analyses: #{output_dir}/")
        IO.puts("Global guide: #{guide_path}")
      end
    end
  end

  # ============================================================================
  # GUIDE BUILDER MODULE
  # ============================================================================

  defmodule GuideBuilder do
    @moduledoc """
    Build global translation guide from individual analyses.
    """

    alias TrackUpstream.{Config, Git, OpenAI}

    @doc """
    Build the global porting guide from individual analyses.
    """
    def build_global_guide(
          analyses,
          plv_start_rev,
          plv_end_rev,
          lvn_start_rev,
          newly_added_files,
          plv_dir
        ) do
      """
      # Phoenix LiveView → LiveView Native: Upstream Porting Guide

      **Generated:** #{DateTime.utc_now() |> DateTime.to_string()}
      **Baseline:** PLV #{plv_start_rev} → LVN #{lvn_start_rev}
      **Upstream Delta:** PLV #{plv_start_rev} → #{plv_end_rev}
      **Files Analyzed:** #{length(analyses)}
      **Relevant New Files:** #{length(newly_added_files)} (renames/refactors + tests for translated modules)

      ---

      ## Purpose

      **TASK:** Upgrade the current version of LiveView Native to incorporate recent changes to Phoenix LiveView, of which it is a derivative.

      **CURRENT STATE:**
      - The Phoenix LiveView dependency has already been updated, causing existing test failures
      - Run `mix test` to see current failures and prioritize changes based on impact

      #{Config.porting_constraints()}

      This guide documents:
      - **Baseline transformation:** How Phoenix LiveView code was originally adapted to LiveView Native (PLV #{plv_start_rev} → LVN #{lvn_start_rev})
      - **Upstream delta:** What changed in Phoenix LiveView that needs porting (PLV #{plv_start_rev} → #{plv_end_rev})
      - **Newly added files:** Descriptions of files added in Phoenix LiveView to help determine relevance (see Addendum)

      **Use this guide to:**
      1. Understand the transformation patterns (PLV → LVN)
      2. Apply those patterns to upstream changes
      3. Identify which newly added files are relevant for LiveView Native

      ---

      ## Project-Global Transformation Rules

      These rules appear across multiple files and represent the core mechanical transformations from Phoenix LiveView to LiveView Native.

      **Apply these rules when porting upstream changes.**

      #{extract_global_rules(analyses)}

      ---

      ## File-Specific Porting Guides

      Each section below shows:
      - **Baseline transformation rules** for that file (PLV #{plv_start_rev} → LVN #{lvn_start_rev})
      - **Upstream delta** for that file (PLV #{plv_start_rev} → #{plv_end_rev})
      - **Porting guidance** specific to that file

      #{build_file_specific_sections(analyses)}

      ---

      ## Statistics

      #{extract_key_insights(analyses)}

      ---

      ## Workflow for Porting

      **SCOPE:** You must systematically review and port ALL upstream changes from ALL #{length(analyses)}
      file pairs documented in this guide. Passing tests is necessary but not sufficient - there may be
      improvements, optimizations, and new features that don't affect current tests but should still be ported.

      **Goal:** Port all upstream changes in a series of logical updates, fixing test failures and ensuring
      no new failures are introduced at each step.

      **IMPORTANT:** The Phoenix LiveView dependency has already been updated, so `mix test` will show existing
      failures. These failures help you PRIORITIZE THE ORDER of porting work, but you will port ALL changes
      documented in this guide, not just the ones that fix tests.

      **Recommended Approach:**

      1. **Assess current state** - Run `mix test` to see existing failures. These failures help you PRIORITIZE
         THE ORDER of porting work, but you will port ALL changes, not just the ones that fix tests.

      2. **Understand the baseline** - Review project-global and file-global transformation rules

      3. **Examine the upstream delta** - See what changed in Phoenix LiveView

      4. **Review newly added files** - Check the Addendum for descriptions of new files

      5. **Create implementation plan** - Create a step for EACH of the #{length(analyses)} file pairs below.
         For each file:
         - Review its "FILE-GLOBAL TRANSFORMATION RULES"
         - Review ALL items in its "UPSTREAM DELTA" section
         - Create a substep to port each upstream delta (unless not applicable - see below)
         - Order the #{length(analyses)} files by impact on test failures (highest impact first)

         Your plan must have at least #{length(analyses)} steps, one per file pair. For each upstream delta,
         you must either:
         - **Port it** - Apply the transformation rules to port the change to LVN
         - **Exclude it** - Document why it's not applicable (e.g., CSS/JS exclusions per constraints,
           web-specific functionality, already implemented differently in LVN, etc.)

         IMPORTANT: Some changes may not be applicable to LiveView Native, but there must be an EXPLICIT
         DETERMINATION for each upstream delta with a clear explanation of why it was ported or excluded.

      6. **Execute steps with subagents (LINEAR - NO PARALLELISM):**
         - Execute steps ONE AT A TIME in sequential order
         - Do NOT run multiple steps in parallel
         - For each step:
           a. Create a dedicated subagent for that step only
           b. Provide the subagent with:
              * Instructions to load this complete porting guide (UPSTREAM_PORTING_GUIDE.md)
              * Details of all the steps
              * The specific step number this agent is tasked with
              * Instructions to focus ONLY on that step
           c. The subagent should:
              * Read the relevant sections of this guide
              * Apply the transformation rules to the specific changes
              * For EACH upstream delta: either port it OR document why it's not applicable
              * Make the code changes
              * Run tests related to this step
              * Verify no NEW test failures are introduced
              * Verify tests, warnings and compilation errors related to this step now pass (or improve)
              * Report completion with test results _or_ report that there is a better step to start with
              * Commit or restore as appropriate
           d. Wait for the subagent to complete and verify success
           e. Only then proceed to the next step
         - Each step builds on previous steps, so order matters

      7. **Handle unique cases** - Review unique semantic changes that don't follow rules

      8. **Validate completeness** - Review ALL #{length(analyses)} "UPSTREAM DELTA" sections and verify:
         ☐ Each upstream delta was either ported OR explicitly excluded (with reason)
         ☐ All tests pass
         ☐ No new compilation warnings
         ☐ Review the Addendum for newly added files - determine if any are relevant

         If ANY upstream delta was not addressed, return to step 5 and add it.

      ## Common Mistakes to Avoid

      ❌ **Stopping when tests pass** - Tests only validate critical paths, not all functionality
      ❌ **Only fixing breaking changes** - You must port improvements/features too
      ❌ **Skipping files without test failures** - They may have new features worth porting
      ❌ **Assuming all changes apply** - Some may not be applicable, but you must explicitly determine this
      ✅ **Systematically work through all #{length(analyses)} file pairs**
      ✅ **Port ALL upstream deltas unless explicitly excluded by constraints or explicitly determined not applicable**
      ✅ **Document your reasoning for any exclusions or non-applicable changes**

      **Example Subagent Prompt:**
      ```
      Task: Complete step X of #{length(analyses)}: [FILE PAIR] of the LiveView Native upgrade

      Context: Read UPSTREAM_PORTING_GUIDE.md section X for this file pair.

      Current State: The Phoenix LiveView dependency has been updated, causing test failures.
      Run `mix test` first to see which tests are currently failing.

      This file has [N] upstream deltas documented. You must address ALL of them.

      Upstream deltas for this file (from the guide):
      1. [specific delta from guide]
      2. [specific delta from guide]
      ...

      For each delta, either:
      - Port it to LVN (apply transformation rules from the guide)
      - Document why it's not applicable (e.g., CSS/JS per constraints, web-specific,
        already implemented differently in LVN, etc.)

      Requirements:
      - Address ALL upstream deltas for this file pair
      - Use transformation rules from the guide
      - Follow the CONSTRAINTS in the guide (see top of UPSTREAM_PORTING_GUIDE.md)
      - Run tests related to this step
      - Ensure no NEW test failures are introduced
      - Verify tests related to this step pass or improve
      - Clear all warnings
      - Do NOT make changes for other file pairs

      Available Resources:
      - Porting guide: UPSTREAM_PORTING_GUIDE.md (in current directory)
      - Phoenix LiveView repo: ../phoenix_live_view
      - To view Phoenix LiveView files at specific revisions:
        * #{plv_start_rev} (baseline): git -C ../phoenix_live_view show #{plv_start_rev}:path/to/file
        * #{plv_end_rev} (target): git -C ../phoenix_live_view show #{plv_end_rev}:path/to/file
      - Current LiveView Native files: in current directory

      When you need more context than provided in the guide diffs, read the full
      Phoenix LiveView files using the git commands above.

      Report when complete with:
      - Summary of what was ported for each delta
      - Any exclusions/non-applicable changes with justification
      - Test results: which tests now pass, any remaining failures
      - Confirmation that no new test failures were introduced
      ```

      ---

      ## Addendum: Newly Added Files

      #{build_newly_added_files_section(newly_added_files, plv_dir, plv_end_rev)}

      """
    end

    # Private functions

    defp build_file_specific_sections(analyses) do
      analyses
      |> Enum.with_index(1)
      |> Enum.map(fn {{plv_file, lvn_file, similarity, analysis}, idx} ->
        """
        ### #{idx}. #{plv_file} → #{lvn_file}

        **Similarity:** #{Float.round(similarity * 100, 2)}%

        #{analysis}

        ---
        """
      end)
      |> Enum.join("\n")
    end

    defp extract_global_rules(analyses) do
      # Use LLM to extract project-global rules from all file-global rules
      api_key = System.get_env("OPENAI_API_KEY")
      unless api_key, do: raise "OPENAI_API_KEY not set"

      config = Config.openai_config()

      # Collect all file-global rules from individual analyses
      all_analyses_text =
        analyses
        |> Enum.map(fn {plv_file, lvn_file, _sim, analysis} ->
          """
          File: #{plv_file} → #{lvn_file}
          #{analysis}
          ---
          """
        end)
        |> Enum.join("\n")

      prompt = """
      TASK: You are helping upgrade LiveView Native to incorporate recent changes to Phoenix LiveView, of which it is a derivative.

      CURRENT STATE:
      - The Phoenix LiveView dependency has already been updated, causing existing test failures
      - Changes should prioritize fixing these test failures
      - Changes should be made in logical steps
      - After each step: ensure no NEW test failures and tests related to the step should pass

      #{Config.porting_constraints()}

      You are analyzing #{length(analyses)} file pair analyses to extract PROJECT-GLOBAL transformation rules.

      Each analysis contains FILE-GLOBAL rules. Your job is to identify rules that appear across MULTIPLE files and consolidate them into PROJECT-GLOBAL rules.

      All individual analyses:
      #{String.slice(all_analyses_text, 0, 50000)}

      Task: Extract PROJECT-GLOBAL transformation rules that appear in multiple files.

      For each project-global rule, provide:
      1. Rule name and pattern (e.g., "Module Namespace Transformation: Phoenix.LiveView → LiveViewNative")
      2. How many files this rule appears in
      3. Brief description of the pattern
      4. 1-2 examples from different files
      5. Any special considerations for this rule (referencing the CONSTRAINTS above when relevant)

      Format as markdown with clear sections.
      """

      response =
        Req.post!(
          "https://api.openai.com/v1/chat/completions",
          json: %{
            model: config.analysis_model,
            messages: [%{role: "user", content: prompt}],
            temperature: 0
          },
          headers: [{"Authorization", "Bearer #{api_key}"}],
          retry: :transient,
          receive_timeout: config.timeout
        )

      case response.status do
        200 ->
          response.body["choices"] |> List.first() |> Map.get("message") |> Map.get("content")

        _ ->
          """
          _Error extracting project-global rules from #{length(analyses)} analyses._

          Failed to analyze common patterns. See individual file analyses below.
          """
      end
    end

    defp extract_key_insights(analyses) do
      """
      - **Total file pairs analyzed:** #{length(analyses)}
      - **Average similarity:** #{calculate_average_similarity(analyses)}%
      - **Individual analyses:** See sections above for complete details
      """
    end

    defp calculate_average_similarity(analyses) do
      if length(analyses) > 0 do
        total = Enum.reduce(analyses, 0.0, fn {_, _, sim, _}, acc -> acc + sim end)
        Float.round(total / length(analyses) * 100, 2)
      else
        0.0
      end
    end

    defp build_newly_added_files_section(newly_added_files, plv_dir, plv_end_rev) do
      if Enum.empty?(newly_added_files) do
        "_No relevant new files were added in this Phoenix LiveView update._"
      else
        """
        The following files were newly added in Phoenix LiveView #{plv_end_rev}. These include:
        1. **Likely renames/refactors** - New files that match existing LVN files already matched to other PLV files
        2. **Tests for translated modules** - New test files that test modules which have been translated to LVN

        Descriptions are provided to help determine when the actual content is relevant for porting to LiveView Native.

        **Files included:** #{length(newly_added_files)}

        #{build_file_descriptions(newly_added_files, plv_dir, plv_end_rev)}
        """
      end
    end

    defp build_file_descriptions(files, plv_dir, plv_rev) do
      IO.puts("Generating descriptions for #{length(files)} newly added files...")

      files
      |> Enum.with_index(1)
      |> Enum.map(fn {file, idx} ->
        IO.puts("  [#{idx}/#{length(files)}] Describing: #{file}")

        case Git.get_file_content(plv_dir, plv_rev, file) do
          {:ok, content} ->
            description = OpenAI.Chat.generate_file_description(file, content)

            """
            ### #{idx}. `#{file}`

            #{description}

            ---
            """

          :error ->
            """
            ### #{idx}. `#{file}`

            _Could not read file content_

            ---
            """
        end
      end)
      |> Enum.join("\n")
    end
  end

  # ============================================================================
  # CLI MODULE (Main orchestration and output)
  # ============================================================================

  defmodule CLI do
    @moduledoc """
    User interface and main orchestration for upstream change tracking.
    """

    alias TrackUpstream.{
      Analysis,
      Config,
      FileMatcher,
      Git,
      OpenAI
    }

    @doc """
    Main entry point for the upstream tracker.
    """
    def run(plv_start_rev, plv_end_rev, lvn_start_rev, opts \\ []) do
      # Validate configuration
      Config.validate!()

      analyze = Keyword.get(opts, :analyze, false)
      plv_dir = "../phoenix_live_view"
      lvn_dir = "."

      IO.puts("Finding closest file matches...")
      IO.puts("Phoenix LiveView: #{plv_start_rev} -> #{plv_end_rev} (in #{plv_dir})")
      IO.puts("LiveView Native: #{lvn_start_rev} (in #{lvn_dir})")
      IO.puts("")

      # Get list of Elixir files from both repos
      plv_start_files = Git.get_elixir_files(plv_dir, plv_start_rev)
      plv_end_files = Git.get_elixir_files(plv_dir, plv_end_rev)
      lvn_start_files = Git.get_elixir_files(lvn_dir, lvn_start_rev)

      # Identify newly added files in PLV
      plv_start_set = MapSet.new(plv_start_files)
      plv_end_set = MapSet.new(plv_end_files)
      newly_added_files = MapSet.difference(plv_end_set, plv_start_set) |> MapSet.to_list()

      IO.puts("Analyzing file similarities...")
      IO.puts("Phoenix LiveView #{plv_start_rev} files: #{length(plv_start_files)}")
      IO.puts("Phoenix LiveView #{plv_end_rev} files: #{length(plv_end_files)}")
      IO.puts("Newly added in PLV: #{length(newly_added_files)}")
      IO.puts("LiveView Native files: #{length(lvn_start_files)}")
      IO.puts("")

      # For each Phoenix LiveView start file, find the closest match
      IO.puts("Matching existing PLV files...")
      concurrency = Config.analysis_config().concurrency

      existing_results =
        plv_start_files
        |> Task.async_stream(
          fn plv_file ->
            FileMatcher.find_closest_match(
              plv_file,
              plv_dir,
              plv_start_rev,
              lvn_start_files,
              lvn_dir,
              lvn_start_rev
            )
          end,
          timeout: :infinity,
          max_concurrency: concurrency
        )
        |> Enum.map(fn {:ok, result} -> result end)
        |> Enum.filter(& &1)
        |> Enum.sort_by(fn {_plv, _lvn, similarity, _verification} -> -similarity end)

      # Build a set of LVN files already matched to existing PLV files
      already_matched_lvn_files =
        MapSet.new(existing_results, fn {_plv, lvn, _sim, _verification} -> lvn end)

      # For newly added files, try to find potential matches in LVN
      IO.puts("\nAnalyzing newly added PLV files...")

      new_file_results =
        newly_added_files
        |> Task.async_stream(
          fn plv_file ->
            FileMatcher.find_closest_match(
              plv_file,
              plv_dir,
              plv_end_rev,
              lvn_start_files,
              lvn_dir,
              lvn_start_rev
            )
          end,
          timeout: :infinity,
          max_concurrency: concurrency
        )
        |> Enum.map(fn {:ok, result} -> result end)
        |> Enum.filter(& &1)
        |> Enum.sort_by(fn {_plv, _lvn, similarity, _verification} -> -similarity end)

      threshold = Config.analysis_config().similarity_threshold

      # Categorize new files based on their matches
      new_with_claimed_match =
        Enum.filter(new_file_results, fn {_, lvn, sim, verification} ->
          is_translation =
            case verification do
              %{"is_translation" => false} -> false
              _ -> true
            end

          sim >= threshold and MapSet.member?(already_matched_lvn_files, lvn) and is_translation
        end)

      new_with_unclaimed_match =
        Enum.filter(new_file_results, fn {_, lvn, sim, verification} ->
          is_translation =
            case verification do
              %{"is_translation" => false} -> false
              _ -> true
            end

          sim >= threshold and not MapSet.member?(already_matched_lvn_files, lvn) and
            is_translation
        end)

      new_with_low_match =
        Enum.filter(new_file_results, fn {_, _, sim, _verification} -> sim < threshold end)

      new_no_match =
        newly_added_files -- Enum.map(new_file_results, fn {plv, _, _, _verification} -> plv end)

      # For claimed matches, find the original PLV file
      new_with_claimed_annotated =
        Enum.map(new_with_claimed_match, fn {new_plv, lvn, sim, verification} ->
          original_plv = Enum.find(existing_results, fn {_plv, lvn_file, _, _} -> lvn_file == lvn end)
          {new_plv, lvn, sim, verification, original_plv}
        end)

      # Filter out files that aren't actual translations or below 70% similarity
      existing_results_filtered =
        Enum.filter(existing_results, fn {_plv, _lvn, sim, verification} ->
          is_high_enough = sim >= threshold

          is_translation =
            case verification do
              %{"is_translation" => false} -> false
              _ -> true
            end

          is_high_enough and is_translation
        end)

      # Find newly added test files that test translated modules
      IO.puts("\nAnalyzing newly added test files for translated modules...")

      # Get list of translated lib files
      translated_lib_files =
        existing_results_filtered
        |> Enum.filter(fn {plv_file, _lvn, _sim, _ver} -> String.starts_with?(plv_file, "lib/") end)
        |> Enum.map(fn {plv_file, _lvn, _sim, _ver} -> plv_file end)

      # Get modules from translated lib files
      translated_modules =
        FileMatcher.get_modules_from_lib_files(plv_dir, plv_end_rev, translated_lib_files)

      # Check newly added test files (exclude e2e tests)
      new_test_files =
        newly_added_files
        |> Enum.filter(fn file ->
          String.starts_with?(file, "test/") and not String.starts_with?(file, "test/e2e/")
        end)

      new_tests_for_translated =
        new_test_files
        |> Task.async_stream(
          fn test_file ->
            case Git.get_file_content(plv_dir, plv_end_rev, test_file) do
              {:ok, content} ->
                IO.write(".")
                tested_modules = OpenAI.Chat.get_tested_modules(test_file, content)

                # Check if any tested module is in our translated set
                if Enum.any?(tested_modules, fn m -> MapSet.member?(translated_modules, m) end) do
                  {test_file, tested_modules,
                   MapSet.intersection(MapSet.new(tested_modules), translated_modules)
                   |> MapSet.to_list()}
                else
                  nil
                end

              _ ->
                nil
            end
          end,
          timeout: :infinity,
          max_concurrency: concurrency
        )
        |> Enum.map(fn {:ok, result} -> result end)
        |> Enum.filter(& &1)

      # Print results
      print_results(
        existing_results_filtered,
        new_with_claimed_annotated,
        new_tests_for_translated,
        new_with_unclaimed_match,
        new_with_low_match,
        new_no_match,
        newly_added_files,
        existing_results,
        plv_start_rev,
        plv_end_rev,
        lvn_start_rev
      )

      # Run detailed analysis if requested
      if analyze do
        IO.puts("")
        IO.puts("=" |> String.duplicate(80))
        IO.puts("DETAILED ANALYSIS PHASE")
        IO.puts("=" |> String.duplicate(80))
        IO.puts("")

        # Collect relevant newly added files for the addendum
        relevant_new_files =
          Enum.map(new_with_claimed_annotated, fn {new_plv, _lvn, _sim, _verification, _original} ->
            new_plv
          end) ++
            Enum.map(new_tests_for_translated, fn {test_file, _all_tested, _matching} ->
              test_file
            end)

        Analysis.run_detailed_analysis(
          plv_start_rev,
          plv_end_rev,
          lvn_start_rev,
          existing_results_filtered,
          relevant_new_files
        )
      end
    end

    # Private functions

    defp print_results(
           existing_results_filtered,
           new_with_claimed_annotated,
           new_tests_for_translated,
           new_with_unclaimed_match,
           new_with_low_match,
           new_no_match,
           newly_added_files,
           existing_results,
           _plv_start_rev,
           _plv_end_rev,
           _lvn_start_rev
         ) do
      IO.puts("")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("MATCHED FILE PAIRS (Existing)")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("")

      for {plv_file, lvn_file, similarity, verification} <- existing_results_filtered do
        verification_text =
          case verification do
            %{"is_translation" => true, "confidence" => conf} -> " ✓ Translation (#{conf})"
            nil -> ""
          end

        IO.puts(
          "#{plv_file}\t#{lvn_file}\t#{Float.round(similarity * 100, 2)}%#{verification_text}"
        )
      end

      IO.puts("")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("NEWLY ADDED PLV FILES - Likely Renames/Refactors")
      IO.puts("(Matches LVN files already matched to other PLV files)")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("")

      if Enum.empty?(new_with_claimed_annotated) do
        IO.puts("(none)")
      else
        for {new_plv, lvn, sim, verification, {old_plv, _, old_sim, _}} <-
              new_with_claimed_annotated do
          verification_text =
            case verification do
              %{"is_translation" => true, "confidence" => conf} -> " ✓ Translation (#{conf})"
              %{"is_translation" => false, "reason" => reason} -> " ✗ Not translation (#{reason})"
              nil -> ""
            end

          IO.puts("NEW: #{new_plv}\t#{Float.round(sim * 100, 2)}%#{verification_text}")
          IO.puts("  -> LVN: #{lvn}")
          IO.puts("  -> OLD: #{old_plv}\t#{Float.round(old_sim * 100, 2)}%")
          IO.puts("")
        end
      end

      IO.puts("=" |> String.duplicate(80))
      IO.puts("NEWLY ADDED PLV FILES - Tests for Translated Modules")
      IO.puts("(New test files that test modules which have been translated)")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("")

      if Enum.empty?(new_tests_for_translated) do
        IO.puts("(none)")
      else
        for {test_file, _all_tested, matching_modules} <- new_tests_for_translated do
          IO.puts("#{test_file}")
          IO.puts("  Tests translated modules: #{Enum.join(matching_modules, ", ")}")
          IO.puts("")
        end
      end

      IO.puts("=" |> String.duplicate(80))
      IO.puts("NEWLY ADDED PLV FILES - Potentially Need LVN Equivalent")
      IO.puts("(Matches unclaimed LVN files - may indicate LVN already has it)")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("")

      if Enum.empty?(new_with_unclaimed_match) do
        IO.puts("(none)")
      else
        for {plv_file, lvn_file, similarity, verification} <- new_with_unclaimed_match do
          verification_text =
            case verification do
              %{"is_translation" => true, "confidence" => conf} -> " ✓ Translation (#{conf})"
              %{"is_translation" => false, "reason" => reason} -> " ✗ Not translation (#{reason})"
              nil -> ""
            end

          IO.puts(
            "#{plv_file}\t#{lvn_file}\t#{Float.round(similarity * 100, 2)}%#{verification_text}"
          )
        end
      end

      # Count files that need porting (weak matches + no matches)
      files_needing_porting = length(new_with_low_match) + length(new_no_match)

      IO.puts("")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("NEWLY ADDED PLV FILES - Need Manual Review")
      IO.puts("(#{files_needing_porting} files with <70% similarity - likely need new implementation)")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("")
      IO.puts("(not shown - use git to review newly added files)")

      IO.puts("")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("SUMMARY")
      IO.puts("=" |> String.duplicate(80))
      IO.puts("Existing file matches (≥70%, verified translations): #{length(existing_results_filtered)}")
      filtered_count = length(existing_results) - length(existing_results_filtered)

      if filtered_count > 0 do
        IO.puts("  (#{filtered_count} matches filtered out: <70% similarity or non-translations)")
      end

      IO.puts("")
      IO.puts("Newly added PLV files: #{length(newly_added_files)}")
      IO.puts("  - Likely renames/refactors: #{length(new_with_claimed_annotated)}")
      IO.puts("  - Tests for translated modules: #{length(new_tests_for_translated)}")
      IO.puts("  - Potentially need LVN equivalent: #{length(new_with_unclaimed_match)}")
      IO.puts("  - Need manual review (<70%): #{files_needing_porting}")
    end
  end
end
