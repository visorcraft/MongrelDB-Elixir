defmodule MongrelDB.MixProject do
  use Mix.Project

  @version "0.64.3"
  @source_url "https://github.com/visorcraft/MongrelDB-Elixir"
  @homepage "https://www.mongreldb.com"

  def project do
    [
      app: :mongreldb,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "MongrelDB",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @homepage,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :inets provides :httpc; :ssl is required for https URLs (loopback only
      # by default, but we include it so a proxy URL does not crash).
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Pure Elixir client for MongrelDB, the embedded and server database with " <>
      "SQL, vector search, full-text search, and AI-native retrieval. Built on " <>
      ":inets/:httpc with no external runtime dependencies."
  end

  defp package do
    [
      licenses: ["MIT", "Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Homepage" => @homepage,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      source_url: @source_url,
      files: ~w(lib mix.exs README.md LICENSE-APACHE LICENSE-MIT .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras:
        ["README.md"] ++
          Path.wildcard("docs/*.md"),
      source_ref: "master",
      source_url: @source_url,
      groups_for_extras: groups_for_extras()
    ]
  end

  defp groups_for_extras do
    [
      Guides: ~w(docs/quickstart.md docs/transactions.md docs/queries.md
        docs/sql.md docs/auth.md docs/errors.md)
    ]
  end
end
