# LiveView 1.1 Template Reference Collision - Complete Analysis

## Executive Summary

LiveView 1.1's new `@keyed` comprehension system with template references has a bug where:
1. Comprehensions create isolated template scopes
2. Sibling function components inherit the wrong template reference
3. This causes template/data mismatches during rendering

**Both regular LiveView (HTML) and LiveViewNative (LVN) are affected**, but the bug manifests differently due to rendering strictness.

## The Bug in 3 Steps

### 1. Template Creation During Diff.render

```elixir
# Parent template has:
# - Position 2: Comprehension (7 static parts)
# - Position 3: live_file_input component (10 static parts, 9 dynamic values)

# What happens:
Position 2 (comprehension):
  - Receives template: {%{}, %{}}  # Empty template map
  - Creates template 0 with 7 static parts
  - Returns template with 1 entry

Position 3 (Input component):
  - Receives template: {%{}, %{}}  # ALSO empty! (chain broken)
  - Creates template 0 with 10 static parts (in its own scope)
  - Returns template with 1 entry
```

### 2. Final Diff Structure (WRONG)

```elixir
%{
  2 => %{k: %{...}, s: 0},           # Comprehension: references template 0
  3 => %{0 => "...", 1 => "...", ..., 8 => "...", s: 0},  # Input: ALSO references template 0!
  p: %{
    0 => ["\n    lv:", ":", ...]    # Comprehension template (7 parts)
    1 => ["", "\n", "<LiveForm...", ...]  # Root template
    # Input's template (10 parts) is MISSING!
  }
}
```

### 3. Rendering Failure

```
to_iodata processes position 3:
- Fetches template 0: ["\n    lv:", ":", ...] (7 static parts)
- Position 3 has: 9 dynamic values
- Template expects: 6 dynamic values (7 parts - 1)
- MISMATCH: Renders as garbled output
```

## Root Cause in Code

**File**: `deps/phoenix_live_view/lib/phoenix_live_view/diff.ex:560-583`

```elixir
defp traverse(%Comprehension{...}, ..., template, ...) do
  if template do
    # Has template - works correctly
  else
    {keyed, keyed_prints, pending, components, template} =
      traverse_keyed(
        entries,
        %{},
        pending,
        components,
        {%{}, %{}},  # <-- BUG: Creates isolated scope instead of using incoming template
        changed?,
        stream != nil,
        has_key?
      )

    diff = %{@static => static, @keyed => keyed}
           |> maybe_add_stream(stream)
           |> maybe_add_template(template)

    {diff, {fingerprint, keyed_prints}, pending, components, nil}  # <-- BUG: Returns nil, breaks chain
  end
end
```

**The bug**:
1. Line 567: `{%{}, %{}}` creates isolated template scope
2. Line 583: Returns `nil` instead of accumulated template
3. Subsequent positions (like position 3) receive `nil` or empty template
4. Each creates template 0 in their own scope
5. Only one template 0 makes it to final `:p` map

## Why Both HTML and LVN Are Affected

### Identical Code Structure

**Regular LiveView (`Phoenix.Component.live_file_input`)**:
```elixir
<%= for entry <- @uploads.avatar.entries do %>
  {@prefix}:{entry.client_name}:{entry.progress}%
  ...
<% end %>
<.live_file_input upload={@uploads.avatar} />
```

**LiveView Native (`LiveViewNativeTest.GameBoy.render`)**:
```elixir
<%= for entry <- @uploads.avatar.entries do %>
  lv:{entry.client_name}:{entry.progress}%
  ...
<% end %>
<.live_file_input upload={@uploads.avatar} />
```

### Debug Evidence Shows Both Process Through Same Code Path

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

Both HTML and LVN comprehensions create isolated template 0s.

## Why The Bug Manifests Differently

### LiveViewNative: **VISIBLE FAILURE**
- LVN parses tags strictly for native rendering
- Garbled output like `lv: id="...": name="..."%` fails tag matching
- Tests fail: 42/42 upload tests
- Error: `expected selector "LiveForm Input[type=\"file\"]" to return a single element, but got none`

### Regular LiveView HTML: **SILENT FAILURE?**
- HTML browsers are forgiving with malformed attributes
- Garbled output might still render functionally
- Tests may pass if they only verify upload functionality, not exact HTML structure
- The `<input>` tag might still work even with wrong attribute separators

**Hypothesis**: Regular LiveView HTML **has the same bug** but:
1. Browsers tolerate the malformed HTML
2. Tests don't verify exact HTML structure
3. Upload functionality works despite garbled intermediate renders

## Comparison: LiveView 1.0 vs 1.1

### LiveView 1.0.18 (WORKED)
```elixir
# No template references - values inline
%{
  d: [[value1, value2, ...], ...],  # @dynamics - inline values
  s: ["static", "parts"]             # Static parts inline
}
```

### LiveView 1.1 (BROKEN)
```elixir
# Template references - shared templates
%{
  k: %{0 => %{0 => "val1", s: 0}, kc: 1},  # @keyed with template refs
  s: 0,                                      # Reference to :p map
  p: %{0 => ["static", "parts"]}            # Shared templates
}
```

The 1.1 optimization (template sharing) introduced the bug when comprehensions create isolated scopes.

## The Fix

### Option 1: Patch LiveView Diff Module

```elixir
# Line 567: Use incoming template if available
{keyed, keyed_prints, pending, components, inner_template} =
  traverse_keyed(
    entries,
    %{},
    pending,
    components,
    template || {%{}, %{}},  # <-- Use incoming template
    changed?,
    stream != nil,
    has_key?
  )

# Line 583: Return accumulated template, not nil
{diff, {fingerprint, keyed_prints}, pending, components, inner_template}  # <-- Return template
```

### Option 2: LiveViewNative Workaround

Restructure templates to avoid comprehension + function component siblings. For example:
- Wrap `live_file_input` in its own render function
- Inline the component content instead of using function components

### Option 3: Report to Phoenix Team

This appears to be a LiveView 1.1 regression that affects all templates using:
- Comprehensions (for loops)
- Followed by function components returning Rendered structs
- In the same parent template

## Next Steps

1. **Verify HTML bug exists**: Create a test that checks exact HTML structure (not just functionality)
2. **Report to Phoenix**: File issue with minimal reproduction case
3. **Implement workaround**: For LiveViewNative until LiveView is fixed
4. **Test the fix**: Apply patch to Diff module and verify all tests pass

## Files Modified for Debugging

- `deps/phoenix_live_view/lib/phoenix_live_view/diff.ex`: Added debug output
- `lib/live_view_native/test/view_tree.ex`: Added position inspection
- `test/support/clients/gameboy/component.ex`: Added Rendered struct inspection

## Test Command

```bash
mix test test/live_view_native/upload/channel_test.exs:413
```

Expected output with current bug:
```
1) test lv with valid token render_change success with upload
   ** (ArgumentError) expected selector "LiveForm Input[type=\"file\"][name=\"avatar\"]"
   to return a single element, but got none

   Garbled output:
   lv: id="phx-...": name="avatar"%
   channel: accept="false"
```
