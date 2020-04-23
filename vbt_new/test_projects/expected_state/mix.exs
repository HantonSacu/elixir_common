defmodule SkafolderTester.MixProject do
  use Mix.Project

  def project do
    [
      app: :skafolder_tester,
      version: "0.1.0",
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix, :gettext] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      preferred_cli_env: preferred_cli_env(),
      dialyzer: dialyzer(),
      releases: releases(),
      build_path: System.get_env("BUILD_PATH", "_build")
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SkafolderTesterApp, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.4.17"},
      {:phoenix_pubsub, "~> 1.1"},
      {:phoenix_ecto, "~> 4.0"},
      {:ecto_sql, "~> 3.1"},
      {:postgrex, ">= 0.0.0"},
      {:gettext, "~> 0.11"},
      {:jason, "~> 1.0"},
      {:plug_cowboy, "~> 2.0"},
      {:vbt, path: "../../.."},
      {:mox, "~> 0.5", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to create, migrate and run the seeds file at once:
  #
  #     $ mix ecto.setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      credo: ["compile", "credo"],
      operator_template: ["compile", &operator_template/1],
      release: release_steps()
    ]
  end

  defp preferred_cli_env,
    do: [credo: :test, dialyzer: :test, release: :prod, operator_template: :prod]

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix],
      ignore_warnings: "dialyzer.ignore-warnings"
    ]
  end

  defp operator_template(_),
    do: IO.puts(SkafolderTester.Config.template())

  defp releases() do
    [
      skafolder_tester: [
        include_executables_for: [:unix],
        steps: [:assemble, &copy_bin_files/1]
      ]
    ]
  end

  # solution from https://elixirforum.com/t/equivalent-to-distillerys-boot-hooks-in-mix-release-elixir-1-9/23431/2
  defp copy_bin_files(release) do
    File.cp_r("rel/bin", Path.join(release.path, "bin"))
    release
  end

  defp release_steps do
    if Mix.env() != :prod or System.get_env("SKIP_ASSETS") == "true" or not File.dir?("assets") do
      []
    else
      [
        "cmd 'cd assets && npm install && npm run deploy'",
        "phx.digest"
      ]
    end
    |> Enum.concat(["release"])
  end
end
