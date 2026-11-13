defmodule PlaywrightEx.Client.ClientStackTrace do
  @upstream "packages/playwright-core/src/client/clientStackTrace.ts"
  @moduledoc """
  Port of `#{@upstream}`. Library frames are those of the `:playwright_ex` application's modules
  (the facade's and the matchers' too), instead of files under the core dir; each is left out,
  so a caller's frames below a library frame (a step's body, a callback's) stay.

  Deviations: the API name recorded by `PlaywrightEx.Runtime.Api.call/3` wins over the stack
  (BEAM drops tail-call frames); without one it comes from the `PlaywrightEx.Client.*` (and
  runtime) frames. Frames are told apart by module, not by file: Node's internals (`internal/`,
  `node:`) are the runtime's own library, OTP's `kernel` and `stdlib` and Elixir's `elixir` (by
  code path, `internal_frame?/1`), and the boxed prefixes are modules
  (`set_boxed_stack_prefixes/1`).
  """
  @library Enum.map(~w(Client Isomorphic Protocol Runtime Transport), &"Elixir.PlaywrightEx.#{&1}.")
  @internal_apps [:kernel, :stdlib, :elixir]

  def capture_library_stack_trace do
    {:current_stacktrace, [_process_info | stack]} = Process.info(self(), :current_stacktrace)
    boxed = boxed_stack_prefixes()
    show_internal = show_internal_stack_frames()

    parsed_frames =
      stack
      |> Enum.map(fn {module, function, arity, location} ->
        frame = %{
          # JS stack frames carry absolute paths (metadata.location.file): see `source_file/2`.
          file: if(file = location[:file], do: to_string(file), else: ""),
          line: location[:line] || 0,
          column: 0,
          function: Exception.format_mfa(module, function, arity)
        }

        is_playwright_library =
          String.starts_with?(Atom.to_string(module), @library)

        %{frame: frame, mfa: {module, function, arity}, isPlaywrightLibrary: is_playwright_library}
      end)
      # utils/stackTrace.ts `parseStackFrame`: `if (!showInternalStackFrames() &&
      # (file.startsWith('internal') || file.startsWith('node:'))) return null;`
      |> Enum.reject(&(!show_internal and !&1.isPlaywrightLibrary and internal_frame?(elem(&1.mfa, 0))))

    # Deepest transition between non-client code calling into client code is the api entry.
    # (BEAM drops tail-call frames, so the entry point recorded by `Runtime.Api.call/3` wins.)
    api_name =
      PlaywrightEx.Runtime.Zones.data(:apiName) ||
        parsed_frames
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_value("", fn [parsed_frame, next] ->
          if parsed_frame.isPlaywrightLibrary and !next.isPlaywrightLibrary,
            do: normalize_api_name(parsed_frame.mfa)
        end)

    # This is for the inspector so that it did not include the test runner stack frames.
    library = library_modules()

    parsed_frames =
      Enum.filter(
        parsed_frames,
        &(&1.frame.file != "" and filter_stack_file(&1, library, boxed, show_internal))
      )

    frames = Enum.map(parsed_frames, &%{&1.frame | file: source_file(elem(&1.mfa, 0), &1.frame.file)})

    %{frames: frames, apiName: api_name}
  end

  # utils/stackTrace.ts `filterStackFile`, of a parsed frame's module: `_coreDir` is the client's
  # namespaces and the application's modules.
  # if (isUnderTest() && file.match(...)) return false;  -- not ported: upstream's own repo layout
  defp filter_stack_file(%{mfa: {module, _, _}} = parsed, library, boxed, show_internal) do
    show_internal or
      not (parsed.isPlaywrightLibrary or Map.has_key?(library, module) or Map.has_key?(boxed, module))
  end

  # Elixir only: the application's modules (the facade's, between the caller's and the client's
  # frames, and the matchers'), read once.
  defp library_modules do
    case :persistent_term.get({__MODULE__, :library}, nil) do
      nil ->
        case Application.spec(:playwright_ex, :modules) do
          nil ->
            %{}

          modules ->
            library = Map.new(modules, &{&1, true})
            :persistent_term.put({__MODULE__, :library}, library)
            library
        end

      library ->
        library
    end
  end

  @doc """
  utils/stackTrace.ts `setBoxedStackPrefixes`, with modules in place of file prefixes: captured
  stacks leave out their frames, as upstream's test runner leaves out its package's
  (`PlaywrightEx.Test`).
  """
  def set_boxed_stack_prefixes(modules) do
    boxed = Map.new(modules, &{&1, true})
    if :persistent_term.get({__MODULE__, :boxed}, %{}) != boxed, do: :persistent_term.put({__MODULE__, :boxed}, boxed)
    :ok
  end

  defp boxed_stack_prefixes, do: :persistent_term.get({__MODULE__, :boxed}, %{})

  # `showInternalStackFrames()`: `getAsBooleanFromENV('PWDEBUGIMPL')`, read on each capture.
  defp show_internal_stack_frames, do: System.get_env("PWDEBUGIMPL") not in [nil, "", "false", "0"]

  # Elixir only: a frame of OTP's or Elixir's own library, as Node's `internal/` and `node:`
  # frames, by its module's code path (an ETS lookup), under the apps' dirs (read once). Their
  # compile-time sources are the build machine's (`/home/runner/...`), so the driver would stat
  # missing files for each.
  defp internal_frame?(module) do
    case :code.is_loaded(module) do
      {:file, :preloaded} -> true
      {:file, path} when is_list(path) -> Enum.any?(internal_dirs(), &:lists.prefix(&1, path))
      _ -> false
    end
  end

  defp internal_dirs do
    case :persistent_term.get({__MODULE__, :internal_dirs}, nil) do
      nil ->
        dirs = for app <- @internal_apps, dir = :code.lib_dir(app), is_list(dir), do: dir ++ ~c"/"
        :persistent_term.put({__MODULE__, :internal_dirs}, dirs)
        dirs

      dirs ->
        dirs
    end
  end

  # Elixir only: BEAM frames carry paths relative to their app's root; a module's compile info has
  # its absolute source. A frame that isn't its module's source (injected code, `nofile`,
  # deterministic builds) stays relative: the driver resolves it against its working directory,
  # the BEAM's at launch. Also `PlaywrightEx.Test`'s step frames.
  @doc false
  def source_file(module, file) do
    if Path.type(file) == :absolute do
      file
    else
      source = module_source(module)
      if source && String.ends_with?(source, "/" <> file), do: source, else: file
    end
  end

  # Not cached: `module_info/1` costs ~1.5 us per frame, ~12 us per capture, noise next to the
  # driver round trip; a cache would be global (grows with runtime-defined modules, a
  # `:persistent_term` write can cost a global GC) or in the caller's process dictionary, and a
  # source moved by a recompile would go stale.
  defp module_source(module) do
    if source = module.module_info(:compile)[:source], do: List.to_string(source)
  rescue
    _ -> nil
  end

  # {PlaywrightEx.Client.Page, :"-wait_for_event/3-fun-0-", 1} -> "page.waitForEvent"
  defp normalize_api_name({module, function, _arity}) do
    [class | _] = module |> Module.split() |> Enum.reverse()
    function = Atom.to_string(function)

    function =
      case Regex.run(~r/^-(.+)\/\d+-/, function) do
        [_, name] -> name
        nil -> function
      end

    # name.match(/(API|JS|CDP|[A-Z])([^\d]+)\d?\.(.*)/): a leading API, JS or CDP lowercased as a whole.
    [_, first, rest] = Regex.run(~r/^(API|JS|CDP|[A-Z]?)(.*)$/s, class)
    String.downcase(first) <> rest <> "." <> camelize(function)
  end

  defp camelize("_" <> rest), do: "_" <> camelize(rest)

  defp camelize(function),
    do: function |> String.split("_") |> then(fn [h | t] -> h <> Enum.map_join(t, &String.capitalize/1) end)
end
