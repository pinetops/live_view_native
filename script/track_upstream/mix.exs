defmodule TrackUpstream.MixProject do
  use Mix.Project

  def project do
    [
      app: :track_upstream,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.4.0"},
      {:sourceror, "~> 1.5"},
      {:text_diff, "~> 0.1"}
    ]
  end
end
