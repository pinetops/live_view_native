# LiveView 1.1 Breaking Change Analysis

## Summary

LiveView 1.1 changed how it tracks comprehension changes from a `@dynamics` list-based system to a `@keyed` map-based system with template references. This change introduces a template sharing bug when a comprehension and a sibling function component exist in the same template.

## The Change: @dynamics to @keyed

### LiveView 1.0.18 Structure
```elixir
# Comprehensions stored values inline
%{
  d: [                    # @dynamics - list of dynamic values
    [value1, value2, ...],
    [value1, value2, ...]
  ],
  s: ["static", "parts"]  # Static parts inline
}
```

### LiveView 1.1 Structure
```elixir
# Comprehensions use keyed tracking with template references
%{
  k: %{                   # @keyed - map of keyed items
    0 => %{0 => "value1", 1 => "value2", s: 0},  # Item 0, references template 0
    kc: 1                 # @keyed_count
  },
  s: 0                    # Reference to template in :p map
}

# Root diff includes template map
%{
  0 => %{...},           # Dynamic position 0
  2 => %{k: %{...}, s: 0},  # Comprehension at position 2
  p: %{                  # @template - shared template map
    0 => ["static", "parts"]
  }
}
```

## The Bug: Template Reference Collision

### Affected Code Pattern

LiveViewNative's upload component creates this structure:

```elixir
def render(assigns, _interface) do
  ~LVN"""
  <LiveForm>
    <%= for entry <- @uploads.avatar.entries do %>
      lv:{entry.client_name}:{entry.progress}%
      ...
    <% end %>
    <.live_file_input upload={@uploads.avatar} />
  </LiveForm>
  """
end
```

This creates:
- **Position 2**: A comprehension with 7 static parts
- **Position 3**: A function component (`live_file_input`) that returns a Rendered struct with 10 static parts (the `<Input>` tag)

### What Happens in LiveView 1.1

1. **Root template starts with empty template map**: `{%{}, %{}}`

2. **Position 2 (comprehension) is processed**:
   - File: `deps/phoenix_live_view/lib/phoenix_live_view/diff.ex`, line 527-584
   - Since this is the first render, `template` is `{%{}, %{}}`
   - Hits the `else` clause at line 560
   - Creates isolated template scope: `{%{}, %{}}`
   - Processes comprehension content
   - Calls `maybe_share_template` which assigns template **0** to comprehension's static parts
   - Returns: `{diff_with_s_0, ..., template_with_one_entry}`
   - **Problem**: Returns the isolated template, breaking the template chain

3. **Position 3 (Input component) is processed**:
   - The Input Rendered struct enters `traverse` at line 412-445
   - Receives template from previous position
   - But the template doesn't have the Input's fingerprint
   - Calls `maybe_share_template` which creates template **0** in its own scope
   - Returns a diff with `s: 0`

4. **Final diff structure**:
```elixir
%{
  2 => %{k: %{...}, s: 0},     # Comprehension - references template 0
  3 => %{0 => " id=...", 1 => " name=...", ..., 8 => "", s: 0},  # Input - also references template 0!
  p: %{
    0 => ["\n    lv:", ":", "%\n    channel:", ...]  # Only comprehension template (7 parts)
  }
}
```

5. **Rendering fails**:
   - When `to_iodata` processes position 3
   - It fetches template 0: `["\n    lv:", ":", ...]` (7 static parts)
   - But position 3 has 9 dynamic values (Input attributes)
   - `one_to_iodata` expects: 7 static parts = 6 dynamic positions
   - Position 3 provides: 9 dynamic values
   - Mismatch causes garbled output: attributes rendered with wrong static separators

### Debug Evidence

From test output:
```
!!! CREATING NEW template 0 for fingerprint 172820... (Input - 10 static parts)
!!! CREATING NEW template 0 for fingerprint 292775... (Comprehension - 7 static parts)
```

Both create "template 0" in their own scopes, but only one makes it to the final `:p` map.

Final template map shows only:
```elixir
%{
  0 => ["\n    lv:", ":", "%\n    channel:", ...],  # 7 parts - comprehension
  1 => ["", "\n", "\n<LiveForm...", ...]            # 5 parts - root
}
```

Input's template (with 10 parts) is **missing entirely**.

## Root Cause in LiveView 1.1

**File**: `deps/phoenix_live_view/lib/phoenix_live_view/diff.ex`
**Function**: `traverse/6` for `%Comprehension{}`
**Lines**: 560-583 (else clause)

```elixir
else
  {keyed, keyed_prints, pending, components, template} =
    traverse_keyed(
      entries,
      %{},
      pending,
      components,
      {%{}, %{}},  # <-- Creates isolated template scope!
      changed?,
      stream != nil,
      has_key?
    )

  diff =
    %{@static => static, @keyed => keyed}
    |> maybe_add_stream(stream)
    |> maybe_add_template(template)

  {diff, {fingerprint, keyed_prints}, pending, components, nil}  # <-- Returns nil, breaking chain!
end
```

**The problems**:
1. Line 567: Creates isolated template `{%{}, %{}}` instead of using/extending incoming template
2. Line 583: Returns `nil` as template instead of passing through the accumulated templates
3. This breaks template accumulation across sibling dynamic positions

## Why It Worked in LiveView 1.0

In LiveView 1.0, there was no template sharing mechanism. Each position had its values inline:

```elixir
# Position 3 in LV 1.0 (simplified)
3 => " id=\"...\" name=\"...\" accept=\"...\" ..."  # Just a string
```

No template references, no collision possible.

## Impact on LiveViewNative

Any LiveViewNative template with:
- A comprehension (for loop)
- Followed by a function component that returns a Rendered struct
- In the same parent template

Will fail with garbled HTML output.

**Failing tests**: 42 upload tests (all use `live_file_input` component after comprehension)

## Critical Discovery: Regular LiveView Has The EXACT Same Pattern!

### Phoenix.LiveViewTest.Support.UploadLive (test/support/live_views/upload_live.ex:13-24)
```elixir
<%= for entry <- @uploads.avatar.entries do %>
  {@prefix}:{entry.client_name}:{entry.progress}%
  channel:{inspect(Phoenix.LiveView.UploadConfig.entry_pid(@uploads.avatar, entry))}
  <%= for msg <- upload_errors(@uploads.avatar) do %>
    config_error:{inspect(msg)}
  <% end %>
  <%= for msg <- upload_errors(@uploads.avatar, entry) do %>
    entry_error:{inspect(msg)}
  <% end %>
  relative path:{entry.client_relative_path}
<% end %>
<.live_file_input upload={@uploads.avatar} />
```

This is **IDENTICAL** to LiveViewNative's failing pattern!

### Phoenix.Component.live_file_input (lib/phoenix_component.ex:3322)
```elixir
def live_file_input(%{upload: upload} = assigns) do
  assigns = assign_new(assigns, :accept, fn -> upload.accept != :any && upload.accept end)

  ~H"""
  <input
    id={@upload.ref}
    type="file"
    name={@upload.name}
    accept={@accept}
    data-phx-hook="Phoenix.LiveFileUpload"
    data-phx-update="ignore"
    data-phx-upload-ref={@upload.ref}
    data-phx-active-refs={join_refs(for(entry <- @upload.entries, do: entry.ref))}
    data-phx-done-refs={join_refs(for(entry <- @upload.entries, entry.done?, do: entry.ref))}
    data-phx-preflighted-refs={
      join_refs(for(entry <- @upload.entries, entry.preflighted?, do: entry.ref))
    }
    data-phx-auto-upload={@upload.auto_upload?}
    {if @upload.max_entries > 1, do: Map.put(@rest, :multiple, true), else: @rest}
  />
  """
end
```

### The Mystery: Why Does Regular LiveView Work But LiveViewNative Fails?

Since the **Diff module is shared** between Phoenix.LiveView.HTMLEngine and LiveViewNative.TagEngine, this bug should affect both equally. Yet regular LiveView's tests pass while LiveViewNative's fail.

**Both implementations are IDENTICAL**:

LiveViewNative.GameBoy.Component.live_file_input:
```elixir
data-phx-active-refs={join_refs(for(entry <- @upload.entries, do: entry.ref))}
data-phx-done-refs={join_refs(for(entry <- @upload.entries, entry.done?, do: entry.ref))}
data-phx-preflighted-refs={join_refs(for(entry <- @upload.entries, entry.preflighted?, do: entry.ref))}
```

Phoenix.Component.live_file_input (regular LiveView):
```elixir
data-phx-active-refs={join_refs(for(entry <- @upload.entries, do: entry.ref))}
data-phx-done-refs={join_refs(for(entry <- @upload.entries, entry.done?, do: entry.ref))}
data-phx-preflighted-refs={join_refs(for(entry <- @upload.entries, entry.preflighted?, do: entry.ref))}
```

**Debug Evidence Shows BOTH Process Through Same Code Path**:

From test output with debugging enabled:
```
@@@ [HTML] COMPREHENSION (if template clause)
    Static parts: 2
    Incoming template has 0 entries
!!! CREATING NEW template 0 for fingerprint 87645...

@@@ [LVN] COMPREHENSION (if template clause)
    Static parts: 7
    Incoming template has 0 entries
!!! CREATING NEW template 0 for fingerprint 292775...
```

Both HTML and LVN comprehensions are creating isolated template 0s.

**The actual difference must be in**:
1. **How attributes with comprehensions are compiled** - HTMLEngine vs TagEngine may generate different Rendered structures for attribute comprehensions
2. **Template merging strategy** - One engine might merge/flatten templates while the other doesn't
3. **When the bug manifests** - Both may have the bug, but it only becomes visible in LVN due to strict tag parsing requirements

**Investigation needed**: Direct comparison of Rendered struct output from HTMLEngine vs TagEngine for the same template to identify the structural difference.

## Potential Fixes

### Option 1: Patch LiveView's comprehension handling
Modify line 567 and 583 to preserve template chain:
```elixir
template || {%{}, %{}},  # Use incoming template if available
...
inner_template  # Return accumulated template, not nil
```

### Option 2: LiveViewNative workaround
Ensure each function component is in its own isolated render context, avoiding siblings.

### Option 3: Report to LiveView team
This appears to be a LiveView 1.1 regression where nested Rendered structs don't properly accumulate templates when sibling to comprehensions.
