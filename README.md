# LiveViewNative

[![Build Status](https://github.com/liveview-native/live_view_native/workflows/Elixir%20CI/badge.svg)](https://github.com/liveview-native/live_view_native/actions) [![Hex.pm](https://img.shields.io/hexpm/v/live_view_native.svg)](https://hex.pm/packages/live_view_native) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/live_view_native)

## About

LiveView Native is a platform for building native applications using [Elixir](https://elixir-lang.org/) and [Phoenix LiveView](https://github.com/phoenixframework/phoenix_live_view). It allows a single LiveView to serve both web and non-web clients by transforming platform-specific template code into native UIs:

```elixir
# lib/my_app_web/live/hello_live.ex
defmodule MyAppWeb.HelloLive do
  use MyAppWeb, :live_view
  use MyAppNative, :live_view
end

# lib/my_app_web/live/hello_live_swiftui.ex
defmodule MyAppWeb.HelloLive.SwiftUI do
  use MyAppNative, [:render_component, format: :swiftui]

  def render(assigns, %{"target" => "watchos"}) do
    ~LVN"""
    <VStack>
      <Text>
        Hello WatchOS!
      </Text>
    </VStack>
    """
  end

  def render(assigns, _interface) do
    ~LVN"""
    <VStack>
      <Text>
        Hello SwiftUI!
      </Text>
    </VStack>
    """
  end
end
```

## Getting started

To get started with LiveView Native, you'll need to have an existing [Phoenix Application](https://hexdocs.pm/phoenix/up_and_running.html) or create a new one.

Add `live_view_native` to your list of dependencies in the `mix.exs` file. In addition to `live_view_native` you may want to include some additional libraries:

```elixir
{:live_view_native, "~> 0.4.0-rc.1"},
{:live_view_native_stylesheet, "~> 0.4.0-rc.1"},
{:live_view_native_swiftui, "~> 0.4.0-rc.1"},
{:live_view_native_live_form, "~> 0.4.0-rc.1"}
```

Then run:

```
$ mix lvn.setup
```

and follow the instructions on how to complete the setup process.

## Tracking Upstream Changes

LiveView Native is derived from Phoenix LiveView and needs to stay in sync with upstream changes. The `mix track_upstream` task helps identify and port changes from Phoenix LiveView to LiveView Native.

### Prerequisites

1. **OpenAI API Key**: The tool uses OpenAI embeddings for semantic code matching and GPT-4o for analysis.
   ```bash
   export OPENAI_API_KEY="your-api-key-here"
   ```

2. **Phoenix LiveView Repository**: Clone the Phoenix LiveView repository as a sibling directory:
   ```bash
   cd ..
   git clone https://github.com/phoenixframework/phoenix_live_view.git
   cd live_view_native
   ```

### Usage

The tool compares Phoenix LiveView changes between two versions and identifies which LiveView Native files need updates:

```bash
mix track_upstream <plv_start_rev> <plv_end_rev> <lvn_start_rev>
```

**Arguments:**
- `plv_start_rev`: Phoenix LiveView version you last synced with (e.g., `v1.0.18`)
- `plv_end_rev`: Phoenix LiveView version you want to upgrade to (e.g., `v1.1.14`)
- `lvn_start_rev`: Current LiveView Native commit (e.g., `5905fd1`)

The `lvn_start_rev` should be the commit where you last completed porting changes from `plv_start_rev`.

**Example:**
```bash
# If LiveView Native was last synced with Phoenix LiveView v1.0.18,
# and you want to upgrade to v1.1.14:
mix track_upstream v1.0.18 v1.1.14 5905fd1
```

### Output

The tool generates:
- **Console output**: Matched file pairs, newly added files, and summary statistics
- **`UPSTREAM_PORTING_GUIDE.md`**: Detailed porting guide with transformation rules and upstream changes
- **`translation_analyses/`**: Individual file-pair analyses

### Working with Claude

To use the generated porting guide with Claude:

1. Run the tracking tool to generate the guide:
   ```bash
   mix track_upstream v1.0.18 v1.1.14 5905fd1
   ```

2. In Claude, provide the guide and ask it to help port the changes:
   ```
   I need to port upstream changes from Phoenix LiveView to LiveView Native.
   Please read UPSTREAM_PORTING_GUIDE.md and help me systematically port all changes.
   ```

3. Claude will create a plan and work through each file pair, applying the documented transformation rules.

### Quick Analysis

To see matched files without generating the full porting guide:

```bash
mix track_upstream v1.0.18 v1.1.14 5905fd1 --skip-analyze
```

## Native Clients

LiveView Native enables client frameworks such as:

| UI Framework     | Devices                                              | LiveView Client |
|------------------|------------------------------------------------------|-----------------|
| SwiftUI          | iPhone, iPad, AppleTV, Apple Watch, MacOS, Apple Vision Pro | [LiveView Native SwiftUI](https://github.com/liveview-native/liveview-client-swiftui) |
| JetPack Compose  | Android family                                       | [LiveView Native Jetpack](https://github.com/liveview-native/liveview-client-jetpack) |
| HTML             |                                                    | [LiveView Native HTML](https://github.com/liveview-native/liveview-client-html) |

## Questions?

Have a question or want some help with LiveView Native?

Check out the `#liveview-native` channel on the [Elixir Lang Slack](https://elixir-lang.slack.com/).
