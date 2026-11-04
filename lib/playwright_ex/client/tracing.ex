defmodule PlaywrightEx.Client.Tracing do
  @upstream "packages/playwright-core/src/client/tracing.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Artifact
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.DisposableStub
  alias PlaywrightEx.Client.LocalUtils

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_includeSources, false)
    put(this, :_additionalSources, [])
    put(this, :_isLive, false)
    put(this, :_isTracing, false)
    # Map<harId, { path, resourcesDir }>
    put(this, :_harRecorders, %{})
    this
  end

  def start(this, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      put(this, :_includeSources, !!options[:sources])
      put(this, :_isLive, !!options[:live])
      snapshots = if is_map(options[:snapshots]), do: options.snapshots, else: %{dom: options[:snapshots]}

      channel_call(
        this,
        :tracingStart,
        %{
          name: options[:name],
          snapshotDom: snapshots[:dom],
          snapshotAria: snapshots[:aria],
          snapshotScreen: snapshots[:screen],
          screencast: options[:screenshots],
          coverage: options[:_coverage],
          live: options[:live]
        },
        TimeoutSettings.k_no_timeout()
      )

      %{traceName: trace_name} =
        channel_call(
          this,
          :tracingStartChunk,
          %{name: options[:name], title: options[:title]},
          TimeoutSettings.k_no_timeout()
        )

      _start_collecting_stacks(this, trace_name, get(this, :_isLive))
    end)

    DisposableStub.new(fn -> stop(this) end)
  end

  def start_chunk(this, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      %{traceName: trace_name} = channel_call(this, :tracingStartChunk, options, TimeoutSettings.k_no_timeout())
      _start_collecting_stacks(this, trace_name, get(this, :_isLive))
    end)

    DisposableStub.new(fn -> stop_chunk(this) end)
  end

  def group(this, name, options \\ %{}) do
    options = options || %{}
    if options[:location], do: set_add(this, :_additionalSources, options.location.file)

    channel_call(
      this,
      :tracingGroup,
      %{name: name, location: options[:location]},
      TimeoutSettings.k_no_timeout()
    )

    DisposableStub.new(fn -> group_end(this) end)
  end

  def group_end(this) do
    channel_call(this, :tracingGroupEnd, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  defp _start_collecting_stacks(this, trace_name, live) do
    if !get(this, :_isTracing) do
      put(this, :_isTracing, true)
      Connection.set_is_tracing(get(this, :_connection), true)
    end

    result =
      if local_utils = Connection.local_utils(get(this, :_connection)),
        do:
          LocalUtils.tracing_started(local_utils, %{
            tracesDir: get(this, :_tracesDir),
            traceName: trace_name,
            live: live
          })

    put(this, :_stacksId, result && result[:stacksId])
  end

  def stop_chunk(this, options \\ %{}) do
    options = options || %{}
    _wrap_api_call(this, fn _ -> _do_stop_chunk(this, options[:path]) end)
    nil
  end

  def stop(this, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      error =
        try do
          _do_stop_chunk(this, options[:path])
          nil
        rescue
          e -> e
        end

      channel_call(this, :tracingStop, %{}, TimeoutSettings.k_no_timeout())
      if error, do: raise(error)
    end)

    nil
  end

  def start_har(this, path, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      if get(this, :_harId), do: raise("HAR recording has already been started")

      if options[:resourcesDir] && String.ends_with?(path, ".zip"),
        do: raise("resourcesDir option is not compatible with a .zip har file")

      default_content = if String.ends_with?(path, ".zip"), do: "attach", else: "embed"

      put(
        this,
        :_harId,
        _record_into_har(this, path, nil, %{
          url: options[:urlFilter],
          updateContent: if(options[:content] == nil, do: default_content, else: options.content),
          updateMode: if(options[:mode] == nil, do: "full", else: options.mode),
          resourcesDir: options[:resourcesDir]
        })
      )
    end)

    DisposableStub.new(fn -> stop_har(this) end)
  end

  def stop_har(this) do
    _wrap_api_call(this, fn _ ->
      har_id = get(this, :_harId)
      if !har_id, do: raise("HAR recording has not been started")
      put(this, :_harId, nil)
      _export_har(this, har_id)
    end)

    nil
  end

  def _record_into_har(this, har, page, options \\ %{}) do
    is_zip = String.ends_with?(har, ".zip")
    url = options[:url]

    %{harId: har_id} =
      channel_call(
        this,
        :harStart,
        %{
          page: page,
          options: %{
            content: options[:updateContent] || "attach",
            urlGlob: if(is_binary(url), do: url),
            urlRegexSource: if(is_struct(url, Regex), do: Regex.source(url)),
            urlRegexFlags: if(is_struct(url, Regex), do: PlaywrightEx.Protocol.Serializers.regex_flags(url)),
            mode: options[:updateMode] || "minimal",
            harPath: if(is_zip, do: nil, else: har),
            resourcesDir: options[:resourcesDir]
          }
        },
        TimeoutSettings.k_no_timeout()
      )

    update(this, :_harRecorders, &Map.put(&1, har_id, %{path: har, resourcesDir: options[:resourcesDir]}))
    har_id
  end

  def _export_har(this, har_id) do
    har_params = get(this, :_harRecorders)[har_id]

    if har_params do
      update(this, :_harRecorders, &Map.delete(&1, har_id))
      is_local = !Connection.is_remote(get(this, :_connection))
      is_zip = String.ends_with?(har_params.path, ".zip")

      if is_local do
        %{entries: entries} =
          channel_call(this, :harExport, %{harId: har_id, mode: "entries"}, TimeoutSettings.k_no_timeout())

        # Server wrote HAR and resources to the user's chosen paths.
        if is_zip do
          local_utils = Connection.local_utils(get(this, :_connection))
          if !local_utils, do: raise("Cannot save zipped HAR in thin clients")

          LocalUtils.zip(local_utils, %{
            zipFile: har_params.path,
            entries: entries,
            mode: "write",
            includeSources: false,
            additionalSources: []
          })
        end
      else
        %{artifact: artifact_channel} =
          channel_call(this, :harExport, %{harId: har_id, mode: "archive"}, TimeoutSettings.k_no_timeout())

        artifact = Artifact.from(artifact_channel)

        if is_zip do
          Artifact.save_as(artifact, har_params.path)
          Artifact.delete(artifact)
        else
          local_utils = Connection.local_utils(get(this, :_connection))
          if !local_utils, do: raise("Uncompressed har is not supported in thin clients")
          Artifact.save_as(artifact, har_params.path <> ".tmp")

          LocalUtils.har_unzip(local_utils, %{
            zipFile: har_params.path <> ".tmp",
            harFile: har_params.path,
            resourcesDir: har_params.resourcesDir
          })

          Artifact.delete(artifact)
        end
      end
    end

    nil
  end

  def _export_all_hars(this) do
    _wrap_api_call(
      this,
      fn _ ->
        Promise.await(
          Promise.all(
            for har_id <- Map.keys(get(this, :_harRecorders)), do: Promise.async(fn -> _export_har(this, har_id) end)
          )
        )
      end,
      %{internal: true}
    )

    nil
  end

  defp _do_stop_chunk(this, file_path) do
    _reset_stack_counter(this)

    additional_sources = get(this, :_additionalSources)
    put(this, :_additionalSources, [])
    stacks_id = get(this, :_stacksId)
    put(this, :_stacksId, nil)

    try do
      _save_chunk(this, file_path, stacks_id, additional_sources)
    rescue
      error ->
        # Release the stack session even on failure, otherwise later traces keep appending to it.
        if stacks_id do
          if local_utils = Connection.local_utils(get(this, :_connection)) do
            try do
              LocalUtils.trace_discarded(local_utils, %{stacksId: stacks_id})
            rescue
              _ -> nil
            end
          end
        end

        reraise error, __STACKTRACE__
    end
  end

  defp _save_chunk(this, file_path, stacks_id, additional_sources) do
    if !file_path do
      # Not interested in artifacts.
      channel_call(this, :tracingStopChunk, %{mode: "discard"}, TimeoutSettings.k_no_timeout())

      if stacks_id,
        do: LocalUtils.trace_discarded(Connection.local_utils(get(this, :_connection)), %{stacksId: stacks_id})

      nil
    else
      local_utils = Connection.local_utils(get(this, :_connection))
      if !local_utils, do: raise("Cannot save trace in thin clients")

      is_local = !Connection.is_remote(get(this, :_connection))

      if is_local do
        result = channel_call(this, :tracingStopChunk, %{mode: "entries"}, TimeoutSettings.k_no_timeout())

        LocalUtils.zip(local_utils, %{
          zipFile: file_path,
          entries: result.entries,
          mode: "write",
          stacksId: stacks_id,
          includeSources: get(this, :_includeSources),
          additionalSources: additional_sources
        })

        nil
      else
        result = channel_call(this, :tracingStopChunk, %{mode: "archive"}, TimeoutSettings.k_no_timeout())

        # The artifact may be missing if the browser closed while stopping tracing.
        if !result[:artifact] do
          if stacks_id, do: LocalUtils.trace_discarded(local_utils, %{stacksId: stacks_id})
          nil
        else
          # Save trace to the final local file.
          artifact = Artifact.from(result.artifact)

          try do
            Artifact.save_as(artifact, file_path)
          rescue
            error ->
              # Delete the artifact best-effort, the save error is the one to surface.
              try do
                Artifact.delete(artifact)
              rescue
                _ -> nil
              end

              reraise error, __STACKTRACE__
          end

          Artifact.delete(artifact)

          LocalUtils.zip(local_utils, %{
            zipFile: file_path,
            entries: [],
            mode: "append",
            stacksId: stacks_id,
            includeSources: get(this, :_includeSources),
            additionalSources: additional_sources
          })

          nil
        end
      end
    end
  end

  def _reset_stack_counter(this) do
    if get(this, :_isTracing) do
      put(this, :_isTracing, false)
      Connection.set_is_tracing(get(this, :_connection), false)
    end
  end
end
