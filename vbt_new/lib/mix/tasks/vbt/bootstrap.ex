defmodule Mix.Tasks.Vbt.Bootstrap do
  @shortdoc "Boostrap project (generate everything!!!)"
  @moduledoc "Boostrap project (generate everything!!!)"

  # credo:disable-for-this-file Credo.Check.Readability.Specs
  use Mix.Task
  alias Mix.Vbt
  alias Mix.Vbt.{ConfigFile, MixFile, SourceFile}

  def run(args) do
    if Mix.Project.umbrella?() do
      Mix.raise("mix vbt.bootstrap can only be run inside an application directory")
    end

    Enum.each(
      ~w/makefile docker circleci github_pr_template credo dialyzer formatter_config
      tool_versions aws_mock/,
      &Mix.Task.run("vbt.gen.#{&1}", args)
    )

    create_from_templates(args)

    adapt_code!()
  end

  defp create_from_templates(args) do
    templates_path = Path.join(~w/#{Application.app_dir(:vbt_new)} priv templates/)

    bindings = [
      app: Mix.Vbt.otp_app(),
      context_folder: to_string(Mix.Vbt.otp_app()),
      app_folder: Macro.underscore(Mix.Vbt.app_module_name()),
      web_folder: "#{Mix.Vbt.otp_app()}_web"
    ]

    {mix_generator_opts, _args} = OptionParser.parse!(args, switches: [force: :boolean])

    for template <- Path.wildcard(Path.join(templates_path, "**/*.eex")) do
      target_file =
        template
        |> Path.relative_to(templates_path)
        |> String.replace(~r/\.eex$/, "")
        # The path in the priv dir may contain <%= %> expressions, so we need to eval the path
        |> EEx.eval_string(bindings)

      content = EEx.eval_file(template, bindings)

      if Mix.Generator.create_file(target_file, content, mix_generator_opts) do
        # If the exec permission bit for the owner in the source template is set, we'll set the
        # same bit in the destination. In doing so we're preserving the exec permission. Note that
        # we're only doing this for the owner, because that's the only bit preserved by git.
        if match?(<<1::1, _rest::6>>, <<File.stat!(template).mode::7>>) do
          new_mode = Bitwise.bor(File.stat!(target_file).mode, 0b1_000_000)
          File.chmod!(target_file, new_mode)
        end
      end
    end
  end

  # ------------------------------------------------------------------------
  # Code adaptation
  # ------------------------------------------------------------------------

  defp adapt_code! do
    source_files()
    |> adapt_gitignore()
    |> adapt_mix()
    |> configure_endpoint()
    |> configure_repo()
    |> adapt_app_module()
    |> drop_prod_secret()
    |> config_bcrypt()
    |> store_source_files!()

    File.rm(Path.join(~w/config prod.secret.exs/))

    disable_credo_checks()
  end

  defp adapt_gitignore(source_files) do
    update_in(
      source_files.gitignore,
      &SourceFile.append(
        &1,
        """

        # Build folder inside devstack container
        /_builds/

        # Ignore ssh folder generated by docker
        .ssh
        """
      )
    )
  end

  defp adapt_mix(source_files) do
    update_in(
      source_files.mix,
      fn mix_file ->
        mix_file
        |> adapt_min_elixir_version()
        |> setup_aliases()
        |> setup_preferred_cli_env()
        |> setup_dialyzer()
        |> setup_release()
        |> MixFile.append_config(:project, ~s|build_path: System.get_env("BUILD_PATH", "_build")|)
        |> Map.update!(
          :content,
          &String.replace(
            &1,
            "#{Mix.Vbt.context_module_name()}.Application",
            "#{Mix.Vbt.app_module_name()}"
          )
        )
      end
    )
  end

  defp adapt_min_elixir_version(mix_file) do
    elixir = Mix.Vbt.tool_versions().elixir

    Map.update!(
      mix_file,
      :content,
      &String.replace(&1, ~r/elixir: ".*"/, ~s/elixir: "~> #{elixir.major}.#{elixir.minor}"/)
    )
  end

  defp setup_aliases(mix_file) do
    mix_file
    |> MixFile.append_config(:aliases, ~s|credo: ["compile", "credo"]|)
    |> MixFile.append_config(
      :aliases,
      ~s|operator_template: ["compile", &operator_template/1]|
    )
  end

  defp setup_preferred_cli_env(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "preferred_cli_env: preferred_cli_env()")
    |> SourceFile.add_to_module("""
    defp preferred_cli_env,
      do: [credo: :test, dialyzer: :test, release: :prod, operator_template: :prod]

    """)
  end

  defp setup_dialyzer(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "dialyzer: dialyzer()")
    |> SourceFile.add_to_module("""
    defp dialyzer do
      [
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: "dialyzer.ignore-warnings"
      ]
    end

    defp operator_template(_),
      do: IO.puts(#{Mix.Vbt.context_module_name()}.Config.template())

    """)
  end

  defp setup_release(mix_file) do
    mix_file
    |> MixFile.append_config(:project, "releases: releases()")
    |> SourceFile.add_to_module("""
    defp releases() do
      [
        #{Mix.Vbt.otp_app()}: [
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

    """)
    |> MixFile.append_config(:aliases, ~s|release: release_steps()|)
    |> SourceFile.add_to_module("""
      defp release_steps do
        if Mix.env != :prod or System.get_env("SKIP_ASSETS") == "true" or not File.dir?("assets") do
          []
        else
          [
            "cmd 'cd assets && npm install && npm run deploy'",
            "phx.digest"
          ]
        end
        |> Enum.concat(["release"])
      end
    """)
  end

  defp adapt_app_module(source_files) do
    update_in(
      source_files.app_module.content,
      &(&1
        |> String.replace(
          ~r/(\s*def start\(.*?do)/s,
          "\\1\n#{Mix.Vbt.context_module_name()}.Config.validate!()\n"
        )
        |> String.replace(
          "defmodule #{Mix.Vbt.context_module_name()}.Application",
          "defmodule #{Mix.Vbt.app_module_name()}"
        ))
    )
  end

  defp drop_prod_secret(source_files) do
    update_in(
      source_files.prod_config.content,
      &String.replace(
        &1,
        ~s/import_config "prod.secret.exs"/,
        ""
      )
    )
  end

  defp disable_credo_checks do
    # We don't check for specs in views, controllers, channels, and resolvers, because specs aren't
    # useful there, and they add some noise.
    Enum.each(
      Path.wildcard("lib/#{Mix.Vbt.otp_app()}_web/**/*.ex"),
      &disable_credo_checks(&1, ["Credo.Check.Readability.Specs"])
    )

    # Same reasoning for the app file.
    disable_credo_checks("lib/#{Mix.Vbt.otp_app()}_app.ex", ~w/Credo.Check.Readability.Specs/)

    # Some helper files created by phx.new violate these checks, so we'll disable them. This is
    # not the code we'll edit, so disabling these checks is fine here.
    disable_credo_checks("lib/#{Mix.Vbt.otp_app()}_web.ex", ~w/
      Credo.Check.Readability.AliasAs
      VBT.Credo.Check.Consistency.ModuleLayout
    /)

    disable_credo_checks("test/support/conn_case.ex", ~w/
      Credo.Check.Readability.AliasAs
      Credo.Check.Design.AliasUsage
    /)

    disable_credo_checks("test/support/data_case.ex", ~w/
      Credo.Check.Design.AliasUsage
      Credo.Check.Readability.Specs
    /)

    disable_credo_checks("test/support/channel_case.ex", ~w/Credo.Check.Design.AliasUsage/)
  end

  defp disable_credo_checks(file, checks) do
    checks
    |> Enum.reduce(
      file |> SourceFile.load!() |> SourceFile.prepend("\n"),
      &SourceFile.prepend(&2, "# credo:disable-for-this-file #{&1}\n")
    )
    |> SourceFile.store!()
  end

  defp config_bcrypt(source_files) do
    update_in(
      source_files.test_config,
      &ConfigFile.prepend(&1, "config :bcrypt_elixir, :log_rounds, 1")
    )
  end

  # ------------------------------------------------------------------------
  # Endpoint configuration
  # ------------------------------------------------------------------------

  defp configure_endpoint(source_files) do
    source_files
    |> update_files(~w/config dev_config test_config prod_config/a, &remove_endpoint_settings/1)
    |> update_in(
      [:prod_config],
      &ConfigFile.update_endpoint_config(
        &1,
        fn config ->
          Keyword.merge(config,
            url: [scheme: "https", port: 443],
            force_ssl: [rewrite_on: [:x_forwarded_proto]],
            server: true
          )
        end
      )
    )
    |> update_in([:endpoint], &setup_runtime_endpoint_config/1)
  end

  defp remove_endpoint_settings(file),
    do: ConfigFile.update_endpoint_config(file, &Keyword.drop(&1, ~w/url http secret_key_base/a))

  defp setup_runtime_endpoint_config(endpoint_file) do
    SourceFile.add_to_module(
      endpoint_file,
      """

      @impl Phoenix.Endpoint
      def init(_type, config) do
        config =
          config
          |> Keyword.put(:secret_key_base, #{Mix.Vbt.context_module_name()}.Config.secret_key_base())
          |> Keyword.update(:url, url_config(), &Keyword.merge(&1, url_config()))
          |> Keyword.update(:http, http_config(), &(http_config() ++ (&1 || [])))

        {:ok, config}
      end

      defp url_config, do: [host: #{Mix.Vbt.context_module_name()}.Config.host()]
      defp http_config, do: [:inet6, port: #{Mix.Vbt.context_module_name()}.Config.port()]
      """
    )
  end

  # ------------------------------------------------------------------------
  # Repo configuration
  # ------------------------------------------------------------------------

  defp configure_repo(source_files) do
    source_files
    |> update_in([:config], &add_global_repo_config/1)
    |> update_files([:dev_config, :test_config], &remove_repo_settings/1)
    |> update_in([:repo], &setup_runtime_repo_config/1)
    |> update_in([:repo, :content], &String.replace(&1, "use Ecto.Repo", "use VBT.Repo"))
  end

  defp add_global_repo_config(config) do
    config
    |> ConfigFile.update_config(&Keyword.merge(&1, generators: [binary_id: true]))
    |> ConfigFile.prepend("""
        config #{inspect(Vbt.otp_app())}, #{inspect(Vbt.repo_module())},
          adapter: Ecto.Adapters.Postgres,
          migration_primary_key: [type: :binary_id],
          migration_timestamps: [type: :utc_datetime_usec],
          otp_app: #{inspect(Vbt.otp_app())}
    """)
  end

  defp remove_repo_settings(file) do
    ConfigFile.update_repo_config(
      file,
      &Keyword.drop(&1, ~w/username password database hostname pool_size/a)
    )
  end

  defp setup_runtime_repo_config(repo_file) do
    SourceFile.add_to_module(
      repo_file,
      """
      @impl Ecto.Repo
      def init(_type, config) do
        config =
          Keyword.merge(
            config,
            url: #{Mix.Vbt.context_module_name()}.Config.db_url(),
            pool_size: #{Mix.Vbt.context_module_name()}.Config.db_pool_size(),
            ssl: #{Mix.Vbt.context_module_name()}.Config.db_ssl()
          )

        {:ok, config}
      end
      """
    )
  end

  # ------------------------------------------------------------------------
  # Common functions
  # ------------------------------------------------------------------------

  defp source_files do
    %{
      gitignore: SourceFile.load!(".gitignore", format?: false),
      mix: SourceFile.load!("mix.exs"),
      config: SourceFile.load!("config/config.exs"),
      dev_config: SourceFile.load!("config/dev.exs"),
      test_config: SourceFile.load!("config/test.exs"),
      prod_config: SourceFile.load!("config/prod.exs"),
      endpoint: load_web_file("endpoint.ex"),
      repo: load_context_file("repo.ex"),
      app_module:
        load_context_file("application.ex", output: Path.join("lib", "#{Vbt.otp_app()}_app.ex"))
    }
  end

  defp update_files(source_files, files, updater),
    do: Enum.reduce(files, source_files, &update_in(&2[&1], updater))

  defp load_web_file(location),
    do: SourceFile.load!(Path.join(["lib", "#{Vbt.otp_app()}_web", location]))

  defp load_context_file(location, opts \\ []),
    do: SourceFile.load!(Path.join(["lib", "#{Vbt.otp_app()}", location]), opts)

  defp store_source_files!(source_files),
    do: source_files |> Map.values() |> Enum.each(&SourceFile.store!/1)
end
