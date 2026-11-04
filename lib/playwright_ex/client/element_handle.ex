defmodule PlaywrightEx.Client.ElementHandle do
  @upstream "packages/playwright-core/src/client/elementHandle.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `ElementHandle extends JSHandle`: the inherited methods (`evaluate`, `jsonValue`, ...) are
  `PlaywrightEx.Client.JSHandle`'s, which take either handle.
  """
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.WritableStream
  alias PlaywrightEx.Isomorphic.MimeType

  # fileUtils.ts fileUploadSizeLimit
  @file_upload_size_limit 50 * 1024 * 1024

  def from(handle) do
    handle
  end

  def from_nullable(handle) do
    if handle, do: from(handle)
  end

  def new(parent, type, guid, initializer) do
    this = JSHandle.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_frame, parent)
    # this._elementChannel = this._channel  -- channels and owners are the same handle
    this
  end

  def as_element(this) do
    this
  end

  def owner_frame(this) do
    Frame.from_nullable(channel_call(this, :ownerFrame, %{}, TimeoutSettings.k_no_timeout())[:frame])
  end

  def content_frame(this) do
    Frame.from_nullable(channel_call(this, :contentFrame, %{}, TimeoutSettings.k_no_timeout())[:frame])
  end

  def get_attribute(this, name) do
    # value === undefined ? null : value
    channel_call(this, :getAttribute, %{name: name}, TimeoutSettings.k_no_timeout())[:value]
  end

  def input_value(this) do
    channel_call(this, :inputValue, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def text_content(this) do
    # value === undefined ? null : value
    channel_call(this, :textContent, %{}, TimeoutSettings.k_no_timeout())[:value]
  end

  def inner_text(this) do
    channel_call(this, :innerText, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def inner_html(this) do
    channel_call(this, :innerHTML, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_checked(this) do
    channel_call(this, :isChecked, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_disabled(this) do
    channel_call(this, :isDisabled, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_editable(this) do
    channel_call(this, :isEditable, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_enabled(this) do
    channel_call(this, :isEnabled, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_hidden(this) do
    channel_call(this, :isHidden, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def is_visible(this) do
    channel_call(this, :isVisible, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def dispatch_event(this, type, event_init \\ %{}) do
    channel_call(
      this,
      :dispatchEvent,
      %{type: type, eventInit: JSHandle.serialize_argument(event_init)},
      TimeoutSettings.k_no_timeout()
    )

    nil
  end

  def scroll_into_view_if_needed(this, options \\ %{}) do
    channel_call(this, :scrollIntoViewIfNeeded, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def hover(this, options \\ %{}) do
    channel_call(this, :hover, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def click(this, options \\ %{}) do
    channel_call(this, :click, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def dblclick(this, options \\ %{}) do
    channel_call(this, :dblclick, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def tap(this, options \\ %{}) do
    channel_call(this, :tap, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def select_option(this, values, options \\ %{}) do
    result =
      channel_call(
        this,
        :selectOption,
        Map.merge(convert_select_option_values(values), options),
        Frame._timeout(get(this, :_frame), options)
      )

    result.values
  end

  def fill(this, value, options \\ %{}) do
    channel_call(this, :fill, Map.merge(%{value: value}, options), Frame._timeout(get(this, :_frame), options))
    nil
  end

  def select_text(this, options \\ %{}) do
    channel_call(this, :selectText, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def set_input_files(this, files, options \\ %{}) do
    frame = owner_frame(this)
    if !frame, do: raise("Cannot set input files to detached element")
    converted = convert_input_files(files, Page.context(Frame.page(frame)))

    channel_call(
      this,
      :setInputFiles,
      Map.merge(converted, options),
      Frame._timeout(get(this, :_frame), options)
    )

    nil
  end

  def focus(this) do
    channel_call(this, :focus, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def type(this, text, options \\ %{}) do
    channel_call(this, :type, Map.merge(%{text: text}, options), Frame._timeout(get(this, :_frame), options))
    nil
  end

  def press(this, key, options \\ %{}) do
    channel_call(this, :press, Map.merge(%{key: key}, options), Frame._timeout(get(this, :_frame), options))
    nil
  end

  def check(this, options \\ %{}) do
    channel_call(this, :check, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def uncheck(this, options \\ %{}) do
    channel_call(this, :uncheck, options, Frame._timeout(get(this, :_frame), options))
    nil
  end

  def set_checked(this, checked, options \\ nil) do
    if checked,
      do: check(this, options || %{}),
      else: uncheck(this, options || %{})

    nil
  end

  def bounding_box(this) do
    # value === undefined ? null : value
    channel_call(this, :boundingBox, %{}, TimeoutSettings.k_no_timeout())[:value]
  end

  def screenshot(this, options \\ %{}) do
    mask = options[:mask]
    copy = Map.put(options, :mask, nil)
    copy = if !copy[:type], do: Map.put(copy, :type, determine_screenshot_type(options)), else: copy

    copy =
      if mask,
        do: Map.put(copy, :mask, Enum.map(mask, &%{frame: &1._frame, selector: &1._selector})),
        else: copy

    result = channel_call(this, :screenshot, copy, Frame._timeout(get(this, :_frame), options))

    if options[:path] do
      mkdir_if_needed(options.path)
      File.write!(options.path, result.binary)
    end

    result.binary
  end

  # $  -- ported as query_selector/2
  def query_selector(this, selector) do
    from_nullable(channel_call(this, :querySelector, %{selector: selector}, TimeoutSettings.k_no_timeout())[:element])
  end

  # $$  -- ported as query_selector_all/2
  def query_selector_all(this, selector) do
    result = channel_call(this, :querySelectorAll, %{selector: selector}, TimeoutSettings.k_no_timeout())
    Enum.map(result.elements, &from/1)
  end

  # $eval  -- ported as eval_on_selector/4
  def eval_on_selector(this, selector, page_function, arg \\ nil) do
    # isFunction: typeof pageFunction === 'function'  -- omitted: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evalOnSelector,
        %{selector: selector, expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  # $$eval  -- ported as eval_on_selector_all/4
  def eval_on_selector_all(this, selector, page_function, arg \\ nil) do
    # isFunction: typeof pageFunction === 'function'  -- omitted: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evalOnSelectorAll,
        %{selector: selector, expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  def wait_for_element_state(this, state, options \\ %{}) do
    channel_call(
      this,
      :waitForElementState,
      Map.merge(%{state: state}, options),
      Frame._timeout(get(this, :_frame), options)
    )

    nil
  end

  def wait_for_selector(this, selector, options \\ %{}) do
    result =
      channel_call(
        this,
        :waitForSelector,
        Map.merge(%{selector: selector}, options),
        Frame._timeout(get(this, :_frame), options)
      )

    from_nullable(result[:element])
  end

  defimpl String.Chars do
    def to_string(this), do: PlaywrightEx.Client.JSHandle.to_string(this)
  end

  # elementHandle.ts module functions

  def convert_select_option_values(values) do
    values = if is_list(values) or values == nil, do: values, else: [values]

    cond do
      values == nil ->
        %{}

      values == [] ->
        %{}

      true ->
        for {value, i} <- Enum.with_index(values),
            value == nil,
            do: raise("options[#{i}]: expected object, got null")

        cond do
          is_element_handle(hd(values)) -> %{elements: values}
          is_binary(hd(values)) -> %{options: Enum.map(values, &%{valueOrLabel: &1})}
          true -> %{options: values}
        end
    end
  end

  defp file_payload_exceeds_size_limit(payloads) do
    Enum.reduce(payloads, 0, fn item, size -> size + if(item[:buffer], do: byte_size(item.buffer), else: 0) end) >=
      @file_upload_size_limit
  end

  # fs.promises.stat / path.resolve: File.dir?/1 and Path.expand/1.
  defp resolve_paths_and_directory_for_input_files(items) do
    {local_paths, local_directory} =
      Enum.reduce(items, {nil, nil}, fn item, {local_paths, local_directory} ->
        # const stat = await fs.promises.stat(item);  -- throws for a missing file, as File.stat!/1
        stat = File.stat!(item)

        if stat.type == :directory do
          if local_directory, do: raise("Multiple directories are not supported")
          {local_paths, Path.expand(item)}
        else
          {(local_paths || []) ++ [Path.expand(item)], local_directory}
        end
      end)

    if local_paths not in [nil, []] and local_directory,
      do: raise("File paths must be all files or a single directory")

    {local_paths, local_directory}
  end

  def convert_input_files(files, context) do
    items = if is_list(files), do: files, else: [files]

    if Enum.any?(items, &is_binary/1) do
      if !Enum.all?(items, &is_binary/1), do: raise("File paths cannot be mixed with buffers")

      {local_paths, local_directory} = resolve_paths_and_directory_for_input_files(items)

      if Connection.is_remote(get(context, :_connection)) do
        files =
          if local_directory,
            do:
              Path.join(local_directory, "**")
              |> Path.wildcard(match_dot: true)
              |> Enum.filter(&File.regular?/1),
            else: local_paths

        %{writableStreams: writable_streams, rootDir: root_dir} =
          ChannelOwner._wrap_api_call(
            context,
            fn _ ->
              channel_call(
                context,
                :createTempFiles,
                %{
                  rootDirName: if(local_directory, do: Path.basename(local_directory)),
                  items:
                    Enum.map(files, fn file ->
                      # (await fs.promises.stat(file)).mtimeMs: Erlang has whole seconds only.
                      last_modified_ms = File.stat!(file, time: :posix).mtime * 1000

                      %{
                        name:
                          if(local_directory, do: Path.relative_to(file, local_directory), else: Path.basename(file)),
                        lastModifiedMs: last_modified_ms
                      }
                    end)
                },
                TimeoutSettings.k_no_timeout()
              )
            end,
            %{internal: true}
          )
          |> Map.put_new(:rootDir, nil)

        for {file, writable_stream} <- Enum.zip(files, writable_streams) do
          writable = WritableStream.from(writable_stream)
          # stream.promises.pipeline(fs.createReadStream(file), writable.stream())
          Enum.into(File.stream!(file, 64 * 1024), WritableStream.stream(writable))
        end

        %{directoryStream: root_dir, streams: if(local_directory, do: nil, else: writable_streams)}
      else
        %{localPaths: local_paths, localDirectory: local_directory}
      end
    else
      payloads = items

      if file_payload_exceeds_size_limit(payloads),
        do: raise("Cannot set buffer larger than 50Mb, please write it to a file and pass its path instead.")

      %{payloads: payloads}
    end
  end

  def determine_screenshot_type(options) do
    if options[:path] do
      mime_type = MimeType.get_mime_type_for_path(options.path)

      case mime_type do
        "image/png" -> "png"
        "image/jpeg" -> "jpeg"
        "image/webp" -> "webp"
        _ -> raise ~s(path: unsupported mime type "#{mime_type || "null"}")
      end
    else
      options[:type]
    end
  end

  # fileUtils.ts mkdirIfNeeded
  @doc false
  def mkdir_if_needed(file_path) do
    # This will harmlessly throw on windows if the dirname is the root directory.
    File.mkdir_p(Path.dirname(file_path))
  end

  # `value instanceof ElementHandle`
  defp is_element_handle(value),
    do: ChannelOwner.is_channel_owner(value) and get(value, :_type) == "ElementHandle"
end
