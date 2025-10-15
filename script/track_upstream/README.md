# Track Upstream

A tool for tracking and analyzing upstream changes from Phoenix LiveView to LiveView Native.

## Overview

This tool helps port changes from an upstream project to a downstream project by:

1. **Identifying analogous implementations** - Finding which downstream files correspond to upstream files
2. **Translating tests** - Identifying which tests should be translated
3. **Generating porting guides** - Creating detailed documentation of transformation rules

## Installation

### Option 1: Standalone Executable (Recommended)

Build the standalone executable:

```bash
cd script/track_upstream
mix deps.get
mix escript.build
```

This creates a `track_upstream` executable. You can copy it to your PATH:

```bash
cp track_upstream ~/bin/  # or /usr/local/bin/
```

### Option 2: Mix Task

Use from within the LiveView Native project:

```bash
mix track_upstream <args>
```

## Usage

```bash
track_upstream <upstream_start_rev> <upstream_end_rev> <downstream_rev> [options]
```

### Arguments

- `upstream_start_rev` - Starting revision/tag in upstream repo (e.g., `v1.0.18`)
- `upstream_end_rev` - Ending revision/tag in upstream repo (e.g., `v1.1.14`)
- `downstream_rev` - Revision/commit in downstream repo to compare (e.g., commit hash)

### Options

- `--upstream-dir <path>` - Path to upstream repository (default: current directory)

### Examples

```bash
# Compare different branches in the same repo
track_upstream main feature-branch abc123

# Compare with an external upstream repo
track_upstream v1.0.18 v1.1.14 5905fd1 --upstream-dir ../phoenix_live_view
```

## Configuration

On first run, the tool generates `.track_upstream_config.md` in your current directory. Edit this file to configure:

- **Upstream Project** name and abbreviation
- **Downstream Project** name, abbreviation, and path
- **Porting Constraints** - project-specific rules for what should/shouldn't be ported

Example configuration:

```markdown
## Upstream Project

**Name:** Phoenix LiveView
**Abbreviation:** PLV

## Downstream Project

**Name:** LiveView Native
**Abbreviation:** LVN
**Repository Path:** .

## Porting Constraints

IMPORTANT CONSTRAINTS when porting from upstream to downstream:

1. **CSS and JS Exclusions:**
   - CSS-related functionality should NOT be translated
   - JavaScript-related functionality should NOT be translated

2. **Module Namespacing:**
   - Phoenix.LiveView → LiveViewNative
   - Phoenix.LiveViewTest → LiveViewNativeTest
```

## Requirements

- Elixir ~> 1.15
- `OPENAI_API_KEY` environment variable must be set
- Git repositories for both upstream and downstream projects

## Output

The tool generates:

1. **Console output** - Matched file pairs and summary statistics
2. **Individual analyses** - `translation_analyses/` directory with per-file analysis
3. **Global porting guide** - `UPSTREAM_PORTING_GUIDE.md` with comprehensive porting instructions

## How It Works

1. **File Matching** - Uses OpenAI embeddings to find semantically similar files between upstream and downstream
2. **LLM Verification** - Verifies matches using GPT to ensure they're actual translations
3. **Analysis** - Uses GPT-4o to analyze diffs and extract transformation rules
4. **Guide Generation** - Compiles all analyses into a comprehensive porting guide

All API calls are cached locally to avoid redundant processing.

## Development

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Build executable
mix escript.build

# Run tests
mix test  # (if tests are added)
```

## License

See main project license.
