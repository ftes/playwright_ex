defmodule PlaywrightEx.Isomorphic.URL do
  @moduledoc """
  Elixir only: the JS `URL` class as the client uses it (`new URL(input, base)`, `href`,
  `origin`). `URI` follows RFC 3986, not the WHATWG URL Standard, so this is a reduced WHATWG
  basic URL parser: special schemes, relative resolution, dot segments, default ports,
  percent-encoding, lowercased and Punycode-encoded domains. Not covered: IPv4 number forms
  (`127.1`), IPv6 compression, IDNA mappings beyond lowercase and NFC, and the rarer
  `file:` quirks (drive letters).
  """

  defstruct [:scheme, :host, :port, :query, :fragment, username: "", password: "", path: []]

  @special_schemes %{"ftp" => 21, "file" => nil, "http" => 80, "https" => 443, "ws" => 80, "wss" => 443}

  # Percent-encode sets (bytes besides the C0 controls, DEL and non-ASCII).
  @fragment_set ~c" \"<>`"
  @query_set ~c" \"#<>"
  @special_query_set @query_set ++ ~c"'"
  @path_set @query_set ++ ~c"?^`{}"
  @userinfo_set @path_set ++ ~c"/:;=@[\\]|"

  @forbidden_host ~c"\0\t\n\r #/:<>?@[\\]^|"

  # new URL(input, base): raises a TypeError-like ArgumentError for an invalid URL.
  def new(input, base \\ nil) do
    base = if base == nil, do: nil, else: new(base)
    input = input |> String.replace(~r/^[\x00-\x20]+|[\x00-\x20]+$/, "") |> String.replace(~r/[\t\n\r]/, "")

    case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)$/s, input) do
      [_, scheme, rest] -> parse_with_scheme(String.downcase(scheme), rest, base)
      nil -> parse_relative(input, base)
    end
  end

  # url.href / url.toString()
  def href(%__MODULE__{} = url) do
    authority =
      cond do
        url.host != nil -> "//" <> credentials(url) <> url.host <> if(url.port, do: ":#{url.port}", else: "")
        is_list(url.path) and length(url.path) > 1 and hd(url.path) == "" -> "/."
        true -> ""
      end

    path = if is_binary(url.path), do: url.path, else: Enum.map_join(url.path, &("/" <> &1))
    query = if url.query, do: "?" <> url.query, else: ""
    fragment = if url.fragment, do: "#" <> url.fragment, else: ""
    url.scheme <> ":" <> authority <> path <> query <> fragment
  end

  # url.origin: a tuple origin for the special schemes but `file:`, an opaque one ("null") otherwise.
  def origin(%__MODULE__{scheme: scheme} = url) when scheme in ["ftp", "http", "https", "ws", "wss"],
    do: scheme <> "://" <> url.host <> if(url.port, do: ":#{url.port}", else: "")

  def origin(%__MODULE__{}), do: "null"

  defp credentials(%{username: "", password: ""}), do: ""
  defp credentials(%{username: username, password: ""}), do: username <> "@"
  defp credentials(%{username: username, password: password}), do: username <> ":" <> password <> "@"

  defp parse_with_scheme("file", rest, base) do
    {head, query, fragment} = split(String.replace(rest, "\\", "/"))
    url = %__MODULE__{scheme: "file", host: "", query: encode_query(query, true), fragment: encode_fragment(fragment)}

    cond do
      String.starts_with?(head, "//") ->
        {host, path} = split_authority(binary_part(head, 2, byte_size(head) - 2))
        host = if host in ["", "localhost"], do: "", else: domain_to_ascii(host)
        %{url | host: host, path: parse_path(String.replace_prefix(path, "/", ""), [])}

      base != nil and base.scheme == "file" and not String.starts_with?(head, "/") ->
        resolve(head, query, fragment, base)

      true ->
        %{url | path: parse_path(String.replace_prefix(head, "/", ""), [])}
    end
  end

  defp parse_with_scheme(scheme, rest, base) do
    special = Map.has_key?(@special_schemes, scheme)
    {head, query, fragment} = split(if special, do: backslashes_to_slashes(rest), else: rest)
    url = %__MODULE__{scheme: scheme, query: encode_query(query, special), fragment: encode_fragment(fragment)}

    cond do
      special and base != nil and base.scheme == scheme and not String.starts_with?(head, "//") ->
        resolve(head, query, fragment, base)

      special ->
        parse_authority(url, String.replace(head, ~r/^\/+/, ""))

      String.starts_with?(head, "//") ->
        parse_authority(url, binary_part(head, 2, byte_size(head) - 2))

      String.starts_with?(head, "/") ->
        %{url | path: parse_path(binary_part(head, 1, byte_size(head) - 1), [])}

      # A space right before the query or fragment is encoded, so it survives serialization.
      query != nil or fragment != nil ->
        %{url | path: String.replace(encode(head, []), ~r/ $/, "%20")}

      true ->
        %{url | path: encode(head, [])}
    end
  end

  defp parse_relative(_input, nil), do: invalid!()

  defp parse_relative(input, %__MODULE__{path: path} = base) when is_binary(path) do
    if String.starts_with?(input, "#"),
      do: %{base | fragment: encode_fragment(binary_part(input, 1, byte_size(input) - 1))},
      else: invalid!()
  end

  defp parse_relative(input, base) do
    special = Map.has_key?(@special_schemes, base.scheme)
    {head, query, fragment} = split(if special, do: backslashes_to_slashes(input), else: input)
    resolve(head, query, fragment, base)
  end

  defp resolve(head, query, fragment, base) do
    special = Map.has_key?(@special_schemes, base.scheme)
    query = encode_query(query, special)
    fragment = encode_fragment(fragment)

    cond do
      String.starts_with?(head, "//") ->
        url = %__MODULE__{scheme: base.scheme, query: query, fragment: fragment}
        parse_authority(url, binary_part(head, 2, byte_size(head) - 2))

      String.starts_with?(head, "/") ->
        %{base | path: parse_path(binary_part(head, 1, byte_size(head) - 1), []), query: query, fragment: fragment}

      head == "" and query == nil ->
        %{base | fragment: fragment}

      head == "" ->
        %{base | query: query, fragment: fragment}

      true ->
        %{base | path: parse_path(head, Enum.drop(base.path, -1)), query: query, fragment: fragment}
    end
  end

  defp parse_authority(url, head) do
    special = Map.has_key?(@special_schemes, url.scheme)
    {authority, path} = split_authority(head)

    {userinfo, host_port} =
      case :binary.matches(authority, "@") do
        [] -> {nil, authority}
        matches -> authority |> String.split_at(elem(List.last(matches), 0)) |> then(fn {u, "@" <> h} -> {u, h} end)
      end

    {host, port} = split_port(host_port)
    port = parse_port(port, @special_schemes[url.scheme])

    host =
      cond do
        url.scheme == "file" and host in ["", "localhost"] -> ""
        special and host == "" -> invalid!()
        special -> domain_to_ascii(host)
        true -> opaque_host(host)
      end

    {username, password} =
      case userinfo && String.split(userinfo, ":", parts: 2) do
        nil -> {"", ""}
        [username] -> {encode(username, @userinfo_set), ""}
        [username, password] -> {encode(username, @userinfo_set), encode(password, @userinfo_set)}
      end

    path =
      cond do
        path != "" -> parse_path(binary_part(path, 1, byte_size(path) - 1), [])
        special -> [""]
        true -> []
      end

    %{url | username: username, password: password, host: host, port: port, path: path}
  end

  defp split_authority(head) do
    case :binary.match(head, "/") do
      {index, _} -> {binary_part(head, 0, index), binary_part(head, index, byte_size(head) - index)}
      :nomatch -> {head, ""}
    end
  end

  defp split_port("[" <> _ = host_port) do
    case String.split(host_port, "]", parts: 2) do
      [host, ""] -> {host <> "]", nil}
      [host, ":" <> port] -> {host <> "]", port}
      _ -> invalid!()
    end
  end

  defp split_port(host_port) do
    case String.split(host_port, ":", parts: 2) do
      [host] -> {host, nil}
      [host, port] -> {host, port}
    end
  end

  defp parse_port(port, _default) when port in [nil, ""], do: nil

  defp parse_port(port, default) do
    if !Regex.match?(~r/^[0-9]+$/, port), do: invalid!()
    port = String.to_integer(port)
    if port > 65_535, do: invalid!()
    if port == default, do: nil, else: port
  end

  # The path state: dot segments are resolved against `path` (already parsed segments).
  defp parse_path(input, path) do
    segments = String.split(input, "/")
    last = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.reduce(path, fn {segment, index}, path ->
      is_last = index == last

      cond do
        String.downcase(segment) in ["..", ".%2e", "%2e.", "%2e%2e"] ->
          path = Enum.drop(path, -1)
          if is_last, do: path ++ [""], else: path

        String.downcase(segment) in [".", "%2e"] ->
          if is_last, do: path ++ [""], else: path

        true ->
          path ++ [encode(segment, @path_set)]
      end
    end)
  end

  defp opaque_host(host) do
    if Enum.any?(@forbidden_host, &String.contains?(host, <<&1>>)), do: invalid!()
    encode(host, [])
  end

  # The host parser for special schemes: domain to ASCII (UTS 46 reduced to lowercase, NFC, Punycode).
  defp domain_to_ascii("[" <> _ = host), do: String.downcase(host)

  defp domain_to_ascii(host) do
    domain = percent_decode(host)
    if !String.valid?(domain), do: invalid!()

    ascii =
      domain
      |> String.downcase()
      |> :unicode.characters_to_nfc_binary()
      |> String.split([".", "。", "．", "｡"])
      |> Enum.map_join(".", &if(&1 =~ ~r/^[\x00-\x7F]*$/, do: &1, else: "xn--" <> punycode(&1)))

    if ascii == "" or Enum.any?(:binary.bin_to_list(ascii), &(&1 < 0x20 or &1 == 0x7F or &1 in [?% | @forbidden_host])),
      do: invalid!()

    ascii
  end

  defp percent_decode(string) do
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, string, fn _, hex -> <<String.to_integer(hex, 16)>> end)
  end

  defp split(rest) do
    [_, head, query, fragment] = Regex.run(~r/^([^?#]*)(\?[^#]*|)(#.*|)$/s, rest)
    {head, drop_first(query), drop_first(fragment)}
  end

  defp drop_first(""), do: nil
  defp drop_first(<<_, rest::binary>>), do: rest

  defp backslashes_to_slashes(rest) do
    {head, query, fragment} = split(rest)

    String.replace(head, "\\", "/") <>
      if(query, do: "?" <> query, else: "") <> if(fragment, do: "#" <> fragment, else: "")
  end

  defp encode_query(nil, _special), do: nil
  defp encode_query(query, special), do: encode(query, if(special, do: @special_query_set, else: @query_set))

  defp encode_fragment(nil), do: nil
  defp encode_fragment(fragment), do: encode(fragment, @fragment_set)

  defp encode(string, set) do
    for <<byte <- string>>, into: "" do
      if byte < 0x20 or byte > 0x7E or byte in set,
        do: "%" <> Base.encode16(<<byte>>),
        else: <<byte>>
    end
  end

  defp invalid!, do: raise(ArgumentError, "Invalid URL")

  # RFC 3492 Punycode encoding of a label.
  @base 36
  @tmin 1
  @tmax 26

  defp punycode(label) do
    input = String.to_charlist(label)
    basic = for c <- input, c < 0x80, into: "", do: <<c>>
    b = byte_size(basic)
    output = if b > 0, do: basic <> "-", else: ""
    punycode(input, 0x80, 0, 72, b, b, output)
  end

  defp punycode(input, _n, _delta, _bias, h, _b, output) when h >= length(input), do: output

  defp punycode(input, n, delta, bias, h, b, output) do
    m = input |> Enum.filter(&(&1 >= n)) |> Enum.min()
    delta = delta + (m - n) * (h + 1)

    {delta, bias, h, output} =
      Enum.reduce(input, {delta, bias, h, output}, fn c, {delta, bias, h, output} ->
        cond do
          c < m ->
            {delta + 1, bias, h, output}

          c == m ->
            output = output <> punycode_digits(delta, bias, @base)
            {0, punycode_adapt(delta, h + 1, h == b), h + 1, output}

          true ->
            {delta, bias, h, output}
        end
      end)

    punycode(input, m + 1, delta + 1, bias, h, b, output)
  end

  defp punycode_digits(q, bias, k) do
    t = if k <= bias, do: @tmin, else: if(k >= bias + @tmax, do: @tmax, else: k - bias)

    if q < t,
      do: punycode_digit(q),
      else: punycode_digit(t + rem(q - t, @base - t)) <> punycode_digits(div(q - t, @base - t), bias, k + @base)
  end

  defp punycode_digit(d) when d < 26, do: <<?a + d>>
  defp punycode_digit(d), do: <<?0 + d - 26>>

  defp punycode_adapt(delta, num_points, first) do
    delta = if first, do: div(delta, 700), else: div(delta, 2)
    delta = delta + div(delta, num_points)
    punycode_adapt(delta, 0)
  end

  defp punycode_adapt(delta, k) when delta > div((@base - @tmin) * @tmax, 2),
    do: punycode_adapt(div(delta, @base - @tmin), k + @base)

  defp punycode_adapt(delta, k), do: k + div((@base - @tmin + 1) * delta, delta + 38)
end
