defmodule PlaywrightEx.Matchers.ToMatchSnapshot do
  @upstream "packages/playwright/src/matchers/toMatchSnapshot.ts"
  @moduledoc """
  Port of `#{@upstream}`: `toHaveScreenshot`. `this` is the matcher state
  (`PlaywrightEx.Matchers.Expect`), options are maps with the JS keys.

  `testInfo` is the running `PlaywrightEx.Test` test (`PlaywrightEx.Matchers.Expect`), which
  resolves the `name` option and holds the `-actual`, `-diff`, `-previous` and `-expected` output
  files. Deviations (architecture: Generated facade): the `path` option is the snapshot in place
  of a `name`, also outside a test, with the output files next to it. `updateSnapshots` comes
  from the expect configuration (`PlaywrightEx.Matchers.Expect`). Stabilization and comparison
  stay on the server (`Page._expectScreenshot`).
  """

  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Screencast
  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Matchers.MatcherHint

  defmodule SnapshotHelper do
    @moduledoc "JS `class SnapshotHelper`: a plain map-like struct (no mutable state)."

    alias PlaywrightEx.Isomorphic.MimeType
    alias PlaywrightEx.Matchers.Expect
    alias PlaywrightEx.Matchers.MatcherHint
    alias PlaywrightEx.Test.TestInfo

    # NonConfigProperties: the ToHaveScreenshotOptions that are not ToHaveScreenshotConfigOptions.
    @non_config_properties [:clip, :fullPage, :mask, :maskColor, :omitBackground, :signal]

    defstruct [
      :name,
      :attachmentBaseName,
      :legacyExpectedPath,
      :previousPath,
      :expectedPath,
      :actualPath,
      :diffPath,
      :mimeType,
      :kind,
      :updateSnapshots,
      :options,
      :matcherName,
      :locator,
      :state
    ]

    # `nameOrOptions` is the options map, with `name` (as upstream's object form) or `path`.
    def new(state, test_info, matcher_name, locator, anonymous_snapshot_extension, config_options, options) do
      options = options || %{}
      {name, options} = Map.pop(options, :name)
      # deviation: the `path` option, in place of a `name` that `testInfo` resolves.
      {expected_path, options} = Map.pop(options, :path)

      if name != nil and expected_path != nil,
        do: raise("#{matcher_name}() takes the name or the path option, not both")

      if (expected_path != nil and !is_binary(expected_path)) or (expected_path == nil and test_info == nil),
        do: raise("#{matcher_name}() requires the path option")

      {name, expected_path, attachment_base_name, output_base_path} =
        if expected_path do
          # deviation: the path option is the snapshot, its outputs are written next to it.
          expected_path = Path.expand(expected_path)
          {"", expected_path, Path.basename(expected_path), expected_path}
        else
          kind = if matcher_name == "toHaveScreenshot", do: "screenshot", else: "snapshot"

          resolved_paths =
            TestInfo._resolve_snapshot_paths(test_info, kind, name, "updateSnapshotIndex", anonymous_snapshot_extension)

          output_base_path = TestInfo._get_output_path(test_info, [resolved_paths.relativeOutputPath])

          {if(is_list(name), do: Path.join(name), else: name || ""), resolved_paths.absoluteSnapshotPath,
           resolved_paths.relativeOutputPath, output_base_path}
        end

      filtered_config_options = Map.drop(config_options, @non_config_properties)
      options = Map.merge(filtered_config_options, options)

      # While comparator is not a part of the public API, it is translated here.
      options =
        if options[:_comparator],
          do: options |> Map.put(:comparator, options._comparator) |> Map.delete(:_comparator),
          else: options

      if options[:maxDiffPixels] != nil and options.maxDiffPixels < 0,
        do: raise("`maxDiffPixels` option value must be non-negative integer")

      if options[:maxDiffPixelRatio] != nil and (options.maxDiffPixelRatio < 0 or options.maxDiffPixelRatio > 1),
        do: raise("`maxDiffPixelRatio` option value must be between 0 and 1")

      mime_type = MimeType.get_mime_type_for_path(Path.basename(expected_path)) || "application/octet-stream"

      # this.comparator = getComparator(this.mimeType);  -- not ported: comparison stays on the server

      %__MODULE__{
        name: name,
        expectedPath: expected_path,
        attachmentBaseName: attachment_base_name,
        legacyExpectedPath: add_suffix_to_file_path(output_base_path, "-expected"),
        previousPath: add_suffix_to_file_path(output_base_path, "-previous"),
        actualPath: add_suffix_to_file_path(output_base_path, "-actual"),
        diffPath: add_suffix_to_file_path(output_base_path, "-diff"),
        options: options,
        matcherName: matcher_name,
        locator: locator,
        updateSnapshots: Expect.expect_config()[:updateSnapshots] || "default",
        mimeType: mime_type,
        state: state,
        kind: if(String.starts_with?(mime_type, "image/"), do: "Screenshot", else: "Snapshot")
      }
    end

    def create_matcher_result(this, message, pass, log \\ nil, attachments \\ nil) do
      unfiltered = %{
        name: this.matcherName,
        expected: this.expectedPath,
        actual: this.actualPath,
        diff: this.diffPath,
        pass: pass,
        message: fn -> message end,
        log: log,
        attachments: attachments
      }

      Map.reject(unfiltered, fn {_, v} -> v == nil end)
    end

    def handle_missing_negated(this) do
      is_write_missing_mode = this.updateSnapshots != "none"

      message =
        "A snapshot doesn't exist at #{this.expectedPath}#{if is_write_missing_mode, do: ~s(, matchers using ".not" won't write them automatically.), else: "."}"

      # NOTE: 'isNot' matcher implies inversed value.
      create_matcher_result(this, message, true)
    end

    def handle_different_negated(this) do
      # NOTE: 'isNot' matcher implies inversed value.
      create_matcher_result(this, "", false)
    end

    def handle_matching_negated(this) do
      message =
        Enum.join(
          [
            "#{this.kind} comparison failed:",
            "",
            indent("Expected result should be different from the actual one.", "  ")
          ],
          "\n"
        )

      # NOTE: 'isNot' matcher implies inversed value.
      create_matcher_result(this, message, true)
    end

    def handle_missing(this, actual) do
      is_write_missing_mode = this.updateSnapshots != "none"

      attachments =
        if is_write_missing_mode do
          write_file_sync(this.expectedPath, actual)

          [
            %{
              name: add_suffix_to_file_path(this.attachmentBaseName, "-expected"),
              contentType: this.mimeType,
              path: this.expectedPath
            }
          ]
        else
          []
        end

      write_file_sync(this.actualPath, actual)

      attachments =
        attachments ++
          [
            %{
              name: add_suffix_to_file_path(this.attachmentBaseName, "-actual"),
              contentType: this.mimeType,
              path: this.actualPath
            }
          ]

      message =
        "A snapshot doesn't exist at #{this.expectedPath}#{if is_write_missing_mode, do: ", writing actual.", else: "."}"

      cond do
        this.updateSnapshots in ["all", "changed", "missing"] ->
          IO.puts(message)
          create_matcher_result(this, message, true, nil, attachments)

        this.updateSnapshots == "default" ->
          Map.merge(create_matcher_result(this, "", true, nil, attachments), %{
            softError: %RuntimeError{message: message},
            shouldNotRetryTest: true
          })

        true ->
          create_matcher_result(this, message, false, nil, attachments)
      end
    end

    def handle_different(this, actual, expected, previous, diff, header, diff_error, log) do
      output = ["#{header}#{indent(diff_error, "  ")}"]
      output = if this.name != "", do: output ++ ["", "  Snapshot: #{this.name}"], else: output

      # Copy the expectation inside the `test-results/` folder for backwards compatibility,
      # so that one can upload `test-results/` directory and have all the data inside.
      attachments =
        for {content, suffix, write_path, attachment_path} <- [
              {expected, "-expected", this.legacyExpectedPath, this.expectedPath},
              {previous, "-previous", this.previousPath, this.previousPath},
              {actual, "-actual", this.actualPath, this.actualPath},
              {diff, "-diff", this.diffPath, this.diffPath}
            ],
            content != nil do
          write_file_sync(write_path, content)

          %{
            name: add_suffix_to_file_path(this.attachmentBaseName, suffix),
            contentType: this.mimeType,
            path: attachment_path
          }
        end

      output =
        if log != nil and log != [],
          do: output ++ [MatcherHint.call_log_text(this.state.utils, log)],
          else: output ++ [""]

      create_matcher_result(this, Enum.join(output, "\n"), false, log, attachments)
    end

    def handle_matching(this) do
      create_matcher_result(this, "", true)
    end

    defp add_suffix_to_file_path(file_path, suffix),
      do: PlaywrightEx.Matchers.ToMatchSnapshot.add_suffix_to_file_path(file_path, suffix)

    defp write_file_sync(path, content), do: PlaywrightEx.Matchers.ToMatchSnapshot.write_file_sync(path, content)
    defp indent(lines, tab), do: PlaywrightEx.Matchers.ToMatchSnapshot.indent(lines, tab)
  end

  # toMatchSnapshot  -- not ported: jest generic assertions (architecture: Generated facade)
  def to_have_screenshot_step_title(name_or_options \\ %{}, _opt_options \\ %{}) do
    name =
      case name_or_options do
        %{} = options -> options[:name]
        name -> name
      end

    if is_list(name), do: Enum.join(name, "/"), else: name || ""
  end

  def to_have_screenshot(this, page_or_locator, options \\ %{}) do
    options = options || %{}
    test_info = Expect.expect_config().testInfo

    # deviation: upstream throws "toHaveScreenshot() must be called during the test" without
    # `testInfo`; the path option works outside a test (`SnapshotHelper.new/7`).

    if Expect.expect_config()[:ignoreSnapshots] do
      %{pass: !this.isNot, message: fn -> "" end, name: "toHaveScreenshot", expected: options[:name] || options[:path]}
    else
      MatcherHint.expect_types(page_or_locator, ["Page", "Locator"], "toHaveScreenshot")

      {page, locator} =
        if is_struct(page_or_locator, PlaywrightEx.Locator),
          do: {Locator.page(page_or_locator), page_or_locator},
          else: {page_or_locator, nil}

      config_options = Expect.expect_config()[:toHaveScreenshot] || %{}
      helper = SnapshotHelper.new(this, test_info, "toHaveScreenshot", locator, nil, config_options, options)
      screenshot_type = %{"image/png" => "png", "image/webp" => "webp"}[helper.mimeType]

      if !screenshot_type,
        do: raise("Screenshot name \"#{Path.basename(helper.expectedPath)}\" must have a '.png' or '.webp' extension")

      MatcherHint.expect_types(page_or_locator, ["Page", "Locator"], "toHaveScreenshot")
      style = load_screenshot_styles(helper.options[:stylePath])
      timeout = if helper.options[:timeout] == nil, do: this.timeout, else: helper.options.timeout

      expect_screenshot_options = %{
        locator: locator,
        animations: helper.options[:animations] || "disabled",
        caret: helper.options[:caret] || "hide",
        clip: helper.options[:clip],
        fullPage: helper.options[:fullPage],
        mask: helper.options[:mask],
        maskColor: helper.options[:maskColor],
        omitBackground: helper.options[:omitBackground],
        scale: helper.options[:scale] || "css",
        style: style,
        isNot: !!this.isNot,
        timeout: timeout,
        signal: helper.options[:signal],
        title: this.title,
        type: screenshot_type,
        comparator: helper.options[:comparator],
        maxDiffPixels: helper.options[:maxDiffPixels],
        maxDiffPixelRatio: helper.options[:maxDiffPixelRatio],
        threshold: helper.options[:threshold]
      }

      has_snapshot = File.exists?(helper.expectedPath)

      cond do
        this.isNot and !has_snapshot ->
          SnapshotHelper.handle_missing_negated(helper)

        # Fast path: there's no screenshot and we don't intend to update it.
        !this.isNot and helper.updateSnapshots == "none" and !has_snapshot ->
          SnapshotHelper.create_matcher_result(helper, "A snapshot doesn't exist at #{helper.expectedPath}.", false)

        true ->
          # Hide overlays during screenshot capture so they don't affect visual comparison.
          Screencast.hide_overlays(Page.screencast(page))

          try do
            _compare(this, helper, page, locator, timeout, has_snapshot, expect_screenshot_options)
          after
            Screencast.show_overlays(Page.screencast(page))
          end
      end
    end
  end

  # The `try` block of `toHaveScreenshot`.
  defp _compare(this, helper, page, locator, timeout, has_snapshot, expect_screenshot_options) do
    header = fn timed_out ->
      MatcherHint.format_matcher_message(this.utils, %{
        promise: this.promise,
        isNot: this.isNot,
        matcherName: "toHaveScreenshot",
        locator: if(locator, do: Locator.to_string(locator)),
        expectation: "expected",
        timeout: timeout,
        timedOut: timed_out
      })
    end

    cond do
      this.isNot ->
        # Having `errorMessage` means we timed out while waiting
        # for screenshots not to match, so screenshots
        # are actually the same in the end.
        expect_screenshot_options = Map.put(expect_screenshot_options, :expected, File.read!(helper.expectedPath))
        is_different = !Page._expect_screenshot(page, expect_screenshot_options)[:errorMessage]

        if is_different,
          do: SnapshotHelper.handle_different_negated(helper),
          else: SnapshotHelper.handle_matching_negated(helper)

      !has_snapshot ->
        # Regenerate a new screenshot by waiting until two screenshots are the same.
        result = Page._expect_screenshot(page, expect_screenshot_options)

        # We tried re-generating new snapshot but failed.
        # This can be due to e.g. spinning animation, so we want to show it as a diff.
        if result[:errorMessage] do
          SnapshotHelper.handle_different(
            helper,
            result[:actual],
            nil,
            result[:previous],
            result[:diff],
            header.(result[:timedOut]),
            result.errorMessage,
            result[:log]
          )
        else
          # We successfully generated new screenshot.
          SnapshotHelper.handle_missing(helper, result.actual)
        end

      true ->
        # General case:
        # - snapshot exists
        # - regular matcher (i.e. not a `.not`)
        expected = File.read!(helper.expectedPath)

        expect_screenshot_options =
          Map.put(expect_screenshot_options, :expected, if(helper.updateSnapshots == "all", do: nil, else: expected))

        result = Page._expect_screenshot(page, expect_screenshot_options)
        actual = result[:actual]

        write_files = fn actual_buffer ->
          write_file_sync(helper.expectedPath, actual_buffer)
          write_file_sync(helper.actualPath, actual_buffer)
          IO.puts(helper.expectedPath <> " is re-generated, writing actual.")

          SnapshotHelper.create_matcher_result(
            helper,
            helper.expectedPath <> " running with --update-snapshots, writing actual.",
            true
          )
        end

        cond do
          !result[:errorMessage] ->
            # Screenshot is matching, but is not necessarily the same as the expected.
            if (helper.updateSnapshots == "all" and actual) && compare_buffers_or_strings(actual, expected) do
              IO.puts(helper.expectedPath <> " is re-generated, writing actual.")
              write_files.(actual)
            else
              SnapshotHelper.handle_matching(helper)
            end

          helper.updateSnapshots in ["changed", "all"] ->
            if actual do
              write_files.(actual)
            else
              SnapshotHelper.handle_different(
                helper,
                actual,
                expect_screenshot_options.expected,
                result[:previous],
                result[:diff],
                header.(result[:timedOut]) <> "  Failed to re-generate expected.\n",
                result.errorMessage,
                result[:log]
              )
            end

          true ->
            SnapshotHelper.handle_different(
              helper,
              actual,
              expect_screenshot_options.expected,
              result[:previous],
              result[:diff],
              header.(result[:timedOut]),
              result.errorMessage,
              result[:log]
            )
        end
    end
  end

  @doc false
  def write_file_sync(a_path, content) do
    File.mkdir_p!(Path.dirname(a_path))
    File.write!(a_path, content)
  end

  @doc false
  def indent(lines, tab) do
    Regex.replace(~r/^(?=.+$)/m, lines, tab)
  end

  # determineFileExtension, compareMagicBytes  -- not ported: toMatchSnapshot

  defp load_screenshot_styles(style_path) when style_path in [nil, ""], do: nil

  defp load_screenshot_styles(style_path) do
    style_paths = if is_list(style_path), do: style_path, else: [style_path]
    styles = Enum.map(style_paths, fn style_path -> String.trim(File.read!(style_path)) end)
    result = styles |> Enum.join("\n") |> String.trim()
    if result == "", do: nil, else: result
  end

  # util.ts addSuffixToFilePath
  @doc false
  def add_suffix_to_file_path(file_path, suffix) do
    ext = Path.extname(file_path)
    base = String.slice(file_path, 0, String.length(file_path) - String.length(ext))
    base <> suffix <> ext
  end

  # @utils/comparators compareBuffersOrStrings, for Buffers: non-nil when they differ.
  defp compare_buffers_or_strings(actual_buffer, expected_buffer) do
    if actual_buffer != expected_buffer, do: %{errorMessage: "Buffers differ"}
  end
end
