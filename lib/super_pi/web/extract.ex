defmodule SuperPi.Web.Extract do
  @moduledoc """
  Turns a fetched body into text a model can read: markdown for HTML, pretty JSON, plain text.

  Guarantees, for any input bytes:

  - it never raises (a failure falls back to the decoded text with tags stripped);
  - the text is valid UTF-8, with control characters removed;
  - `page/3` and the `:max_chars` option never return more than `max_chars` characters. A
    character is a Unicode code point, counted the same way everywhere (`char_count/1`).

  ## HTML

  The tree is parsed with Floki. `script`, `style`, `noscript`, `template`, `svg`, `iframe`,
  `nav`, `footer`, `aside`, `button`, hidden elements and ARIA navigation and footer
  landmarks are dropped. The extraction root is the first `<main>`, else all `<article>`
  elements, else `<body>`. Without `<main>` or `<article>` the page `<header>` is dropped too.
  The markdown covers headings, paragraphs, lists, links, emphasis, code, blockquotes, tables
  and images that have alt text. The `text` format keeps the same structure without markup.

  Parsing a large page is the expensive step. The caller runs `extract/3` under
  `SuperPi.Env.SandboxRunner.run_isolated/2` for a deadline and a heap limit.

  ## Other types

  JSON is pretty-printed (falling back to the text if it does not parse). PDF is not extracted:
  `kind/2` reports `:pdf` and the caller refuses it with a message that names the `artifact`
  argument. Other text types pass through.

  ## Character sets

  The body is decoded from the BOM, the `Content-Type` charset or an HTML `<meta charset>`.
  UTF-8, UTF-16, ISO-8859-1 and Windows-1252 are converted. Any other charset is read as UTF-8
  and invalid bytes become U+FFFD.
  """

  @max_links 30
  @max_depth 100
  @max_title 300
  @dropped "script, style, noscript, template, svg, iframe, object, embed, canvas, nav, footer, aside, button, select, dialog, [hidden], [role=navigation], [role=contentinfo]"
  @block ~w(p div section article main header address figure figcaption details summary dl dt dd fieldset body html)
  @inline_skip ~w(head title meta link base)

  # Windows-1252 differs from ISO-8859-1 in 0x80-0x9F.
  @cp1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  @type kind :: :html | :json | :text | :pdf | :binary | :unknown
  @type result :: %{
          kind: kind(),
          title: String.t() | nil,
          text: String.t(),
          links: [String.t()],
          chars: non_neg_integer(),
          offset: non_neg_integer(),
          next_offset: non_neg_integer() | nil,
          truncated: boolean()
        }

  @doc """
  Classifies a response by `Content-Type`, and by a prefix of the body when the type says
  nothing. `body` may be `nil` to classify on the header alone: a missing or generic type then
  gives `:unknown`.
  """
  @spec kind(String.t() | nil, binary() | nil) :: kind()
  def kind(content_type, body) do
    case media_type(content_type) do
      t when t in ["text/html", "application/xhtml+xml"] -> :html
      "application/pdf" -> :pdf
      t when t in ["application/json", "text/json"] -> :json
      t when t in ["", "application/octet-stream", "binary/octet-stream"] -> sniff(body)
      t -> if text_type?(t), do: :text, else: :binary
    end
  end

  defp text_type?(t) do
    String.starts_with?(t, "text/") or String.ends_with?(t, "+xml") or
      t in ~w(application/xml application/javascript application/x-ndjson application/yaml application/x-yaml application/toml)
  end

  defp media_type(nil), do: ""

  defp media_type(content_type),
    do:
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()
      |> json_suffix()

  defp json_suffix(t), do: if(String.ends_with?(t, "+json"), do: "application/json", else: t)

  defp sniff(nil), do: :unknown

  defp sniff(body) do
    head = binary_part(body, 0, min(byte_size(body), 1024))
    lower = head |> String.trim_leading() |> String.downcase()

    cond do
      String.starts_with?(head, "%PDF-") -> :pdf
      String.starts_with?(lower, ["<!doctype html", "<html"]) -> :html
      String.contains?(head, <<0>>) -> :binary
      true -> :text
    end
  end

  @doc """
  Extracts text from a body.

  Options: `:format` (`"markdown"` default, `"text"` or `"raw"`), `:base_url` (resolves relative
  links), `:offset` and `:max_chars` (page the text, see `page/3`; without `:max_chars` the whole
  text is returned).
  """
  @spec extract(binary(), String.t() | nil, keyword()) :: result()
  def extract(body, content_type, opts \\ []) do
    body = if is_binary(body), do: body, else: ""
    format = Keyword.get(opts, :format, "markdown")
    kind = kind(content_type, body)

    {title, text, links} =
      try do
        convert(kind, format, body, content_type, Keyword.get(opts, :base_url))
      rescue
        _ -> fallback(body, content_type)
      catch
        _, _ -> fallback(body, content_type)
      end

    text = scrub(text)

    {chunk, info} =
      paginate(text, Keyword.get(opts, :offset, 0), Keyword.get(opts, :max_chars, :all))

    %{
      kind: kind,
      title: title && title |> scrub() |> String.slice(0, @max_title),
      text: chunk,
      links: links,
      chars: info.chars,
      offset: info.offset,
      next_offset: info.next_offset,
      truncated: info.truncated
    }
  end

  @doc """
  Returns the page of `text` that starts at code point `offset` and holds at most `max_chars`
  code points, with the continuation offset. `text` must be valid UTF-8.
  """
  @spec page(String.t(), non_neg_integer(), pos_integer()) :: {String.t(), map()}
  def page(text, offset, max_chars) when is_binary(text), do: paginate(text, offset, max_chars)

  defp paginate(text, offset, max_chars) do
    total = char_count(text)
    offset = if is_integer(offset) and offset > 0, do: min(offset, total), else: 0
    rest = skip(text, offset)

    case max_chars do
      n when is_integer(n) and n >= 0 ->
        chunk = take(rest, n)
        taken = char_count(chunk)
        done? = offset + taken >= total

        {chunk,
         %{
           chars: total,
           offset: offset,
           next_offset: if(done?, do: nil, else: offset + taken),
           truncated: not done?
         }}

      _ ->
        {rest, %{chars: total, offset: offset, next_offset: nil, truncated: false}}
    end
  end

  @doc "Number of code points in a valid UTF-8 binary."
  @spec char_count(binary()) :: non_neg_integer()
  def char_count(text), do: count(text, 0)

  defp count(<<>>, n), do: n
  defp count(<<_::utf8, rest::binary>>, n), do: count(rest, n + 1)
  defp count(<<_, rest::binary>>, n), do: count(rest, n + 1)

  defp skip(text, 0), do: text
  defp skip(<<>>, _), do: <<>>
  defp skip(<<_::utf8, rest::binary>>, n), do: skip(rest, n - 1)
  defp skip(<<_, rest::binary>>, n), do: skip(rest, n - 1)

  defp take(text, n), do: binary_part(text, 0, bytes_of(text, n, 0))

  defp bytes_of(_text, 0, acc), do: acc
  defp bytes_of(<<>>, _n, acc), do: acc
  defp bytes_of(<<c::utf8, rest::binary>>, n, acc), do: bytes_of(rest, n - 1, acc + utf8_size(c))
  defp bytes_of(<<_, rest::binary>>, n, acc), do: bytes_of(rest, n - 1, acc + 1)

  defp utf8_size(c) when c < 0x80, do: 1
  defp utf8_size(c) when c < 0x800, do: 2
  defp utf8_size(c) when c < 0x10000, do: 3
  defp utf8_size(_), do: 4

  # --- Conversion ----------------------------------------------------------------------------

  defp convert(:html, "raw", body, ct, _base), do: {nil, decode_text(body, ct, true), []}
  defp convert(:html, format, body, ct, base), do: html(decode_text(body, ct, true), format, base)

  defp convert(:json, "raw", body, ct, _base), do: {nil, decode_text(body, ct, false), []}

  defp convert(:json, _format, body, ct, _base) do
    text = decode_text(body, ct, false)

    case Jason.decode(text) do
      {:ok, data} -> {nil, Jason.encode!(data, pretty: true), []}
      {:error, _} -> {nil, text, []}
    end
  end

  defp convert(_kind, _format, body, ct, _base), do: {nil, decode_text(body, ct, false), []}

  defp fallback(body, ct) do
    text = decode_text(body, ct, false)
    {nil, text |> String.replace(~r/<[^>]*>/, " ") |> String.replace(~r/[ \t]+/, " "), []}
  rescue
    _ -> {nil, "", []}
  end

  defp html(source, format, base) do
    case Floki.parse_document(source) do
      {:ok, tree} ->
        title = title(tree)
        {root, rooted?} = root(tree)
        root = Floki.filter_out(root, if(rooted?, do: @dropped, else: @dropped <> ", header"))
        ctx = %{mode: if(format == "text", do: :text, else: :markdown), base: base}
        text = root |> render(ctx, 0) |> cleanup()
        {title || first_heading(root), text, links(root, base)}

      {:error, _} ->
        fallback(source, nil)
    end
  end

  defp root(tree) do
    case Floki.find(tree, "main, [role=main]") do
      [first | _] ->
        {[first], true}

      [] ->
        case Floki.find(tree, "article") do
          [] ->
            case Floki.find(tree, "body") do
              [body | _] -> {[body], false}
              [] -> {tree, false}
            end

          articles ->
            {articles, true}
        end
    end
  end

  defp title(tree) do
    case Floki.find(tree, "title") do
      [node | _] -> blank_to_nil(collapse(Floki.text(node)))
      [] -> nil
    end
  end

  defp first_heading(root) do
    case Floki.find(root, "h1") do
      [node | _] -> blank_to_nil(collapse(Floki.text(node)))
      [] -> nil
    end
  end

  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp links(root, base) do
    root
    |> Floki.attribute("a", "href")
    |> Enum.map(&absolute(&1, base))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  defp absolute(href, base) when is_binary(href) do
    uri = URI.merge(base || "", String.trim(href))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      URI.to_string(%{uri | fragment: nil})
    end
  rescue
    _ -> nil
  end

  defp absolute(_href, _base), do: nil

  # --- Rendering -----------------------------------------------------------------------------

  defp render(nodes, ctx, depth) when is_list(nodes) do
    nodes
    |> Enum.map(&{element?(&1), render_node(&1, ctx, depth)})
    |> Enum.reject(fn {_, text} -> text == "" end)
    |> join_inline()
  end

  # The parser drops whitespace-only text nodes, so `<b>a</b> <i>b</i>` arrives as two adjacent
  # elements. A space goes between them unless one side already has whitespace. Text nodes keep
  # their own spaces, and blocks bring their own newlines.
  defp join_inline(pieces) do
    {out, _} =
      Enum.reduce(pieces, {[], nil}, fn {element?, text}, {acc, prev} ->
        glue? =
          element? and prev != nil and not String.match?(prev, ~r/\s\z/) and
            not String.match?(text, ~r/\A\s/)

        {[if(glue?, do: [" ", text], else: text) | acc], if(element?, do: text, else: nil)}
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp element?({tag, _, _}) when is_binary(tag), do: true
  defp element?(_), do: false

  defp render_node(text, _ctx, _depth) when is_binary(text), do: collapse(text)
  defp render_node({:comment, _}, _ctx, _depth), do: ""
  defp render_node({:pi, _, _}, _ctx, _depth), do: ""
  defp render_node({:doctype, _, _, _}, _ctx, _depth), do: ""

  defp render_node({tag, _attrs, _children} = node, _ctx, depth)
       when depth > @max_depth and is_binary(tag), do: block(collapse(Floki.text(node)))

  defp render_node({tag, _attrs, _children}, _ctx, _depth) when tag in @inline_skip, do: ""

  defp render_node({tag, _attrs, children}, ctx, depth) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    text = children |> render(ctx, depth + 1) |> flatten_inline()
    level = String.to_integer(String.slice(tag, 1, 1))

    if text == "",
      do: "",
      else:
        block(
          if(ctx.mode == :markdown, do: String.duplicate("#", level) <> " " <> text, else: text)
        )
  end

  defp render_node({tag, _attrs, children}, ctx, depth) when tag in ~w(ul ol) do
    items =
      children
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.map(fn {"li", _, li} ->
        li |> render(ctx, depth + 1) |> String.trim() |> String.replace(~r/\n{2,}/, "\n")
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {body, i} ->
        bullet = if tag == "ol", do: "#{i}. ", else: "- "
        bullet <> indent_tail(body, String.length(bullet))
      end)

    if items == [], do: render(children, ctx, depth + 1), else: block(Enum.join(items, "\n"))
  end

  defp render_node({"pre", _, _} = node, ctx, _depth) do
    code = String.trim_trailing(Floki.text(node, sep: ""), "\n")

    if code == "",
      do: "",
      else: block(if(ctx.mode == :markdown, do: "```\n" <> code <> "\n```", else: code))
  end

  defp render_node({"code", _, children}, ctx, depth) do
    text = children |> render(ctx, depth + 1) |> String.trim()

    if text == "" or ctx.mode == :text or String.contains?(text, "`"),
      do: text,
      else: "`" <> text <> "`"
  end

  defp render_node({tag, _, children}, ctx, depth) when tag in ~w(strong b em i) do
    text = children |> render(ctx, depth + 1)
    mark = if tag in ["strong", "b"], do: "**", else: "*"
    trimmed = String.trim(text)

    cond do
      trimmed == "" or ctx.mode == :text or String.contains?(trimmed, "\n") -> text
      true -> pad(text, mark <> trimmed <> mark)
    end
  end

  defp render_node({"a", attrs, children}, ctx, depth) do
    text = children |> render(ctx, depth + 1)
    trimmed = String.trim(text)
    href = absolute(attr(attrs, "href"), ctx.base)

    cond do
      trimmed == "" -> ""
      href == nil or ctx.mode == :text or String.contains?(trimmed, "\n") -> text
      true -> pad(text, "[" <> trimmed <> "](" <> href <> ")")
    end
  end

  defp render_node({"img", attrs, _}, ctx, _depth) do
    alt = (attr(attrs, "alt") || "") |> collapse() |> String.trim()
    src = absolute(attr(attrs, "src"), ctx.base)

    cond do
      alt == "" -> ""
      ctx.mode == :markdown and src != nil -> "![" <> alt <> "](" <> src <> ")"
      true -> alt
    end
  end

  defp render_node({"br", _, _}, _ctx, _depth), do: "\n"

  defp render_node({"hr", _, _}, ctx, _depth),
    do: if(ctx.mode == :markdown, do: block("---"), else: "\n\n")

  defp render_node({"blockquote", _, children}, ctx, depth) do
    text = children |> render(ctx, depth + 1) |> cleanup()

    cond do
      text == "" -> ""
      ctx.mode == :text -> block(text)
      true -> block(text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1)))
    end
  end

  defp render_node({"table", _, _} = table, ctx, depth) do
    rows =
      table
      |> Floki.find("tr")
      |> Enum.map(fn {"tr", _, cells} ->
        cells
        |> Enum.filter(&match?({t, _, _} when t in ["td", "th"], &1))
        |> Enum.map(fn {_, _, cell} ->
          cell |> render(ctx, depth + 1) |> flatten_inline() |> String.replace("|", "/")
        end)
      end)
      |> Enum.reject(&(&1 == []))

    case rows do
      [] ->
        ""

      [head | tail] when ctx.mode == :markdown ->
        block(
          Enum.join(
            [row(head), row(Enum.map(head, fn _ -> "---" end)) | Enum.map(tail, &row/1)],
            "\n"
          )
        )

      all ->
        block(Enum.map_join(all, "\n", &Enum.join(&1, " | ")))
    end
  end

  defp render_node({tag, _, children}, ctx, depth) when tag in @block,
    do: block(render(children, ctx, depth + 1))

  defp render_node({tag, _, children}, ctx, depth)
       when tag in ~w(table thead tbody tfoot tr td th),
       do: block(render(children, ctx, depth + 1))

  defp render_node({_tag, _attrs, children}, ctx, depth), do: render(children, ctx, depth + 1)
  defp render_node(_other, _ctx, _depth), do: ""

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |"

  # A block is set apart by blank lines. An empty block renders as nothing.
  defp block(text) do
    text = String.trim(text)
    if text == "", do: "", else: "\n\n" <> text <> "\n\n"
  end

  defp flatten_inline(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # Keeps the leading and trailing space of an inline run, so `a <b>b</b> c` keeps its spaces.
  defp pad(original, replacement) do
    lead = if String.match?(original, ~r/\A\s/), do: " ", else: ""
    trail = if String.match?(original, ~r/\s\z/), do: " ", else: ""
    lead <> replacement <> trail
  end

  defp indent_tail(text, width) do
    [first | rest] = String.split(text, "\n")
    Enum.join([first | Enum.map(rest, &(String.duplicate(" ", width) <> &1))], "\n")
  end

  defp collapse(text), do: String.replace(text, ~r/[ \t\r\n\f]+/, " ")

  defp cleanup(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # --- Character sets ------------------------------------------------------------------------

  # `sniff_meta?` also looks for an HTML `<meta charset>` in the first 2 KiB.
  defp decode_text(body, content_type, sniff_meta?) do
    {charset, body} = charset(body, content_type, sniff_meta?)
    to_utf8(body, charset)
  end

  defp charset(<<0xEF, 0xBB, 0xBF, rest::binary>>, _ct, _meta?), do: {:utf8, rest}
  defp charset(<<0xFF, 0xFE, rest::binary>>, _ct, _meta?), do: {{:utf16, :little}, rest}
  defp charset(<<0xFE, 0xFF, rest::binary>>, _ct, _meta?), do: {{:utf16, :big}, rest}

  defp charset(body, content_type, meta?) do
    declared = declared_charset(content_type) || (meta? && meta_charset(body))
    {charset_atom(declared), body}
  end

  defp declared_charset(nil), do: nil

  defp declared_charset(content_type) do
    case Regex.run(~r/charset\s*=\s*"?([\w\-:.]+)/i, content_type) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp meta_charset(body) do
    head = binary_part(body, 0, min(byte_size(body), 2048))

    case Regex.run(~r/<meta[^>]+charset\s*=\s*["']?([\w\-:.]+)/i, head) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp charset_atom(nil), do: :utf8
  defp charset_atom(false), do: :utf8

  defp charset_atom(name) do
    case String.downcase(name) do
      n when n in ~w(utf-8 utf8) -> :utf8
      n when n in ~w(iso-8859-1 latin1 latin-1 l1 us-ascii ascii) -> :latin1
      n when n in ~w(windows-1252 cp1252 x-cp1252) -> :cp1252
      "utf-16le" -> {:utf16, :little}
      n when n in ~w(utf-16 utf-16be) -> {:utf16, :big}
      _ -> :utf8
    end
  end

  defp to_utf8(body, :utf8), do: body
  defp to_utf8(body, :latin1), do: :unicode.characters_to_binary(body, :latin1, :utf8)

  defp to_utf8(body, :cp1252) do
    for <<b <- body>>, into: "" do
      <<Map.get(@cp1252, b, b)::utf8>>
    end
  end

  defp to_utf8(body, {:utf16, endian}) do
    case :unicode.characters_to_binary(body, {:utf16, endian}, :utf8) do
      text when is_binary(text) -> text
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
    end
  end

  # Valid UTF-8, no control characters except tab and newline, `\r\n` as `\n`.
  defp scrub(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "")
  end

  defp scrub(_), do: ""
end
