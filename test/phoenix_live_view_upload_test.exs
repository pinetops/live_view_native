defmodule Phoenix.LiveView.UploadComparisonTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint LiveViewNativeTest.Endpoint

  setup do
    {:ok, conn: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})}
  end

  defmodule TestUploadLive do
    use Phoenix.LiveView
    import Phoenix.Component

    def render(assigns) do
      ~H"""
      <form phx-change="validate" phx-submit="save">
        <%= for entry <- @uploads.avatar.entries do %>
          lv:{entry.client_name}:{entry.progress}%
          channel:{inspect(Phoenix.LiveView.UploadConfig.entry_pid(@uploads.avatar, entry))}
          relative path:{entry.client_relative_path}
        <% end %>
        <.live_file_input upload={@uploads.avatar} />
        <button type="submit">save</button>
      </form>
      """
    end

    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(:uploaded_files, [])
       |> allow_upload(:avatar, accept: ~w(.jpg .jpeg .png), max_entries: 3)}
    end

    def handle_event("validate", _params, socket) do
      {:noreply, socket}
    end

    def handle_event("save", _params, socket) do
      {:noreply, socket}
    end
  end

  test "regular LiveView HTML upload with comprehension + component", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/test-upload")

    html = render(lv)
    IO.puts("\n=== REGULAR LIVEVIEW HTML OUTPUT ===")
    IO.puts(html)
    IO.puts("=== END ===\n")

    # Check if input tag is properly rendered
    assert html =~ ~r/<input[^>]*type="file"[^>]*>/
    assert html =~ ~r/name="avatar"/
  end
end
