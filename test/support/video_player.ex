defmodule PlaywrightEx.VideoPlayer do
  @upstream "tests/library/videoPlayer.ts"
  @moduledoc """
  Port of upstream `#{@upstream}`: extracts the frames of a recorded video with ffmpeg and
  reads 10x10 RGBA pixel blocks of them.

  ffmpeg is the one Playwright installs with every browser (upstream's
  `registry.findExecutable('ffmpeg')`, asked from the driver's own registry), else `ffmpeg` on
  PATH. `skip_reason/0` is for `@tag skip:` when neither exists.
  """

  import Bitwise

  alias PlaywrightEx.TestBrowser

  # `cache`  -- not ported: frames are decoded on demand (immutable struct)
  defstruct [:fileName, :output, :duration, :frames, :videoWidth, :videoHeight, :fps]

  @doc "`new VideoPlayer(fileName)`."
  def new(file_name) do
    ffmpeg = ffmpeg() || raise "ffmpeg not found: #{skip_reason()}"
    # Force output frame rate to 25 fps as otherwise it would produce one image per timebase unit
    # which is 1 / (25 * 1000).
    {output, _status} =
      System.cmd(ffmpeg, ["-i", file_name, "-r", "25", "#{file_name}-%04d.png"], stderr_to_stdout: true)

    lines = String.split(output, "\n")

    frames_line =
      Enum.find(lines, &String.starts_with?(&1, "frame=")) || raise "No frame data in the output:\n#{output}"

    frames_line =
      frames_line
      |> :binary.matches("frame=")
      |> List.last()
      |> then(fn {i, _} -> binary_part(frames_line, i, byte_size(frames_line) - i) end)

    [_, frames] = Regex.run(~r/frame=\s+(\d+)/, frames_line)
    stream_line = Enum.find(lines, &String.starts_with?(String.trim(&1), "Stream #0:0"))
    [_, width, height] = Regex.run(~r/, (\d+)x(\d+),/, stream_line)
    [_, fps] = Regex.run(~r/, ([\d.]+) fps,/, stream_line)
    duration_line = Enum.find(lines, &String.starts_with?(String.trim(&1), "Duration"))
    [_, hours, minutes, seconds] = Regex.run(~r/Duration: (\d+):(\d\d):(\d\d.\d\d)/, duration_line)

    %__MODULE__{
      fileName: file_name,
      output: output,
      duration: ((String.to_integer(hours) * 60 + String.to_integer(minutes)) * 60 + parse_float(seconds)) * 1000,
      frames: String.to_integer(frames),
      videoWidth: String.to_integer(width),
      videoHeight: String.to_integer(height),
      fps: parse_float(fps)
    }
  end

  def find_frame(player, frame_predicate, offset \\ nil) do
    Enum.find_value(1..player.frames//1, fn f ->
      frame = frame(player, f, offset)
      if frame_predicate.(frame.data), do: frame
    end)
  end

  def seek_last_frame(player, offset \\ nil), do: frame(player, player.frames, offset)

  @doc "A `%{width: 10, height: 10, data: rgba}` block of frame `frame` (1-based) at `offset`."
  def frame(player, frame, offset \\ nil) do
    %{x: x, y: y} = offset || %{x: 10, y: 10}
    gap = String.duplicate("0", 4 - String.length(Integer.to_string(frame)))
    buffer = File.read!("#{player.fileName}-#{gap}#{frame}.png")
    # PNG.sync.read + PNG.bitblt(decoded, dst, x, y, 10, 10, 0, 0)
    %{width: 10, height: 10, data: png_bitblt(buffer, x, y, 10, 10)}
  end

  @doc """
  Not in upstream's VideoPlayer: `jpegjs.decode(buffer)` (video.spec.ts) as
  `%{width, height, data: rgba}`, via ffmpeg's mjpeg decoder and the PNG decoder.
  """
  def decode_jpeg(buffer) do
    ffmpeg = ffmpeg() || raise "ffmpeg not found: #{skip_reason()}"
    dir = Path.join(System.tmp_dir!(), "playwright_ex-jpeg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.write!(Path.join(dir, "in.jpeg"), buffer)

      args = [
        "-nostdin",
        "-f",
        "image2pipe",
        "-c:v",
        "mjpeg",
        "-i",
        "in.jpeg",
        "-frames:v",
        "1",
        "-update",
        "1",
        "out.png"
      ]

      {_output, 0} = System.cmd(ffmpeg, args, cd: dir, stderr_to_stdout: true)
      png = File.read!(Path.join(dir, "out.png"))
      <<_::binary-16, width::32, height::32, _::binary>> = png
      %{width: width, height: height, data: png_bitblt(png, 0, 0, width, height)}
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  The ffmpeg executable: the registry's (`registry.findExecutable('ffmpeg').executablePath()`
  of the driver), else `ffmpeg` on PATH, else `nil`.
  """
  def ffmpeg do
    TestBrowser.registry_executable("ffmpeg") || System.find_executable("ffmpeg")
  end

  @doc "`nil` when ffmpeg is available, else a skip reason."
  def skip_reason do
    if !ffmpeg(),
      do: "env: no ffmpeg (Playwright installs it with any browser: mix playwright_ex.install; or put ffmpeg on PATH)"
  end

  defp parse_float(string) do
    {float, ""} = Float.parse(string)
    float
  end

  # PNG.sync.read (pngjs) + PNG.bitblt: enough of a decoder for ffmpeg's 8-bit, non-interlaced
  # RGB(A) PNGs. Filters only look left and up, so only the rows up to `y + h` and the columns
  # up to `x + w` are unfiltered. Returns RGBA (alpha 255 for RGB, as pngjs).
  defp png_bitblt(<<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>>, x, y, w, h) do
    {%{width: width, bpp: bpp}, idat} = png_chunks(chunks, nil, [])
    data = :zlib.uncompress(IO.iodata_to_binary(idat))
    stride = width * bpp
    prefix = min((x + w) * bpp, stride)

    data
    |> unfilter_rows(stride, prefix, bpp, y + h, :binary.copy(<<0>>, prefix), [])
    |> Enum.drop(y)
    |> Enum.map(&rgba(binary_part(&1, x * bpp, w * bpp), bpp))
    |> IO.iodata_to_binary()
  end

  defp rgba(block, 4), do: block
  defp rgba(block, 3), do: for(<<r, g, b <- block>>, into: <<>>, do: <<r, g, b, 255>>)

  defp png_chunks(<<len::32, type::binary-4, data::binary-size(len), _crc::32, rest::binary>>, header, idat) do
    case type do
      "IHDR" ->
        <<width::32, _height::32, 8, color_type, _compression, _filter, 0>> = data
        png_chunks(rest, %{width: width, bpp: if(color_type == 6, do: 4, else: 3)}, idat)

      "IDAT" ->
        png_chunks(rest, header, [idat, data])

      "IEND" ->
        {header, idat}

      _ ->
        png_chunks(rest, header, idat)
    end
  end

  defp unfilter_rows(_data, _stride, _prefix, _bpp, 0, _prev, rows), do: Enum.reverse(rows)

  defp unfilter_rows(data, stride, prefix, bpp, count, prev, rows) do
    <<filter, line::binary-size(^stride), rest::binary>> = data
    row = unfilter(filter, binary_part(line, 0, prefix), prev, bpp, 0, <<>>)
    unfilter_rows(rest, stride, prefix, bpp, count - 1, row, [row | rows])
  end

  defp unfilter(0, line, _prev, _bpp, 0, <<>>), do: line
  defp unfilter(_filter, <<>>, _prev, _bpp, _i, out), do: out

  defp unfilter(filter, <<x, rest::binary>>, prev, bpp, i, out) do
    a = if i >= bpp, do: :binary.at(out, i - bpp), else: 0
    b = :binary.at(prev, i)
    c = if i >= bpp, do: :binary.at(prev, i - bpp), else: 0

    value =
      case filter do
        1 -> x + a
        2 -> x + b
        3 -> x + div(a + b, 2)
        4 -> x + paeth(a, b, c)
      end

    unfilter(filter, rest, prev, bpp, i + 1, <<out::binary, band(value, 255)>>)
  end

  defp paeth(a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end
end
