defmodule SuperPi.Properties.WebExtractTest do
  @moduledoc """
  Extraction takes bytes from anywhere, so it holds three guarantees for any input: it never raises,
  its text is valid UTF-8, and a page never holds more than `max_chars` characters. Paging is
  lossless: the pages joined give the full text.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SuperPi.Web.Extract

  @types [
    nil,
    "text/html",
    "text/html; charset=utf-8",
    "text/html; charset=iso-8859-1",
    "text/html; charset=windows-1252",
    "text/plain; charset=utf-16le",
    "text/plain",
    "application/json",
    "application/xml",
    "application/octet-stream",
    "image/png",
    "application/pdf",
    "text/html; charset=bogus"
  ]
  @formats ["markdown", "text", "raw"]

  defp fragment do
    one_of([
      member_of(
        ~w(<div> </div> <p> </p> <span> </span> <b> </b> <i> </i> <a> </a> <ul> </ul> <ol> </ol> <li> </li> <table> </table> <tr> <td> </td> <th> <pre> </pre> <code> </code> <blockquote> </blockquote> <h1> </h1> <h2> <br> <hr> <img> <main> </main> <article> </article> <nav> <script> </script> <style> </style> <svg> <form> <input> <button> <!-- --> <![CDATA[ <?x <!doctype <html> <body> <head> <title> </title> < > & &amp; &lt; &#0; &#xD800; &#x110000; &bogus; ")
      ),
      map(
        member_of([
          "/x",
          "https://a.example/p#f",
          "javascript:1",
          "mailto:x@y",
          "//h.example",
          "",
          "http://[::1"
        ]),
        &~s(<a href="#{&1}">)
      ),
      string(:printable, max_length: 20),
      binary(max_length: 12)
    ])
  end

  defp soup, do: map(list_of(fragment(), max_length: 60), &Enum.join/1)

  defp body do
    one_of([
      binary(max_length: 400),
      string(:printable, max_length: 300),
      soup(),
      soup(),
      map(soup(), &(&1 <> String.duplicate("<div>", 300)))
    ])
  end

  defp opts do
    gen(
      all(
        format <- member_of(@formats),
        base <- member_of([nil, "https://example.com/dir/", "not a url", ""]),
        do: [format: format, base_url: base]
      )
    )
  end

  property "extract never raises and always returns valid UTF-8, for any bytes, type and format" do
    check all(input <- body(), type <- member_of(@types), opts <- opts()) do
      result = Extract.extract(input, type, opts)
      assert String.valid?(result.text)
      assert result.title == nil or String.valid?(result.title)
      assert Enum.all?(result.links, &String.valid?/1)
      assert is_integer(result.chars) and result.chars >= 0
      refute result.text =~ ~r/[\x00-\x08\x0B-\x1F\x7F]/
      assert {:ok, _} = Jason.encode(Map.take(result, [:text, :title, :links]))
    end
  end

  property "the text never exceeds max_chars, however the input and offset look" do
    check all(
            input <- body(),
            type <- member_of(@types),
            opts <- opts(),
            max <- integer(0..200),
            offset <- integer(-5..400)
          ) do
      result = Extract.extract(input, type, [offset: offset, max_chars: max] ++ opts)
      assert Extract.char_count(result.text) <= max
      assert String.valid?(result.text)
      assert result.truncated == (result.next_offset != nil)

      if result.next_offset,
        do: assert(result.next_offset == result.offset + Extract.char_count(result.text))
    end
  end

  property "pages joined give the full text" do
    check all(input <- body(), type <- member_of(@types), max <- integer(1..120)) do
      full = Extract.extract(input, type, [])
      pages = collect(full.text, 0, max, [])
      assert Enum.join(pages) == full.text
      assert Enum.all?(pages, &(Extract.char_count(&1) <= max))
    end
  end

  property "page/3 counts code points, not bytes or graphemes" do
    check all(
            text <- string(:printable, max_length: 80),
            max <- integer(0..40),
            offset <- integer(0..100)
          ) do
      {chunk, info} = Extract.page(text, offset, max)
      assert Extract.char_count(chunk) <= max
      assert Extract.char_count(chunk) == min(max, max(info.chars - info.offset, 0))
      assert info.chars == length(String.codepoints(text))
      assert String.valid?(chunk)
    end
  end

  property "HTML never leaks script or style text" do
    check all(
            noise <- string(:alphanumeric, min_length: 6, max_length: 12),
            type <- member_of(["text/html", nil])
          ) do
      html =
        "<html><head><style>.a{content:'#{noise}S'}</style></head><body><script>var x='#{noise}J'</script><main><p>visible</p></main></body></html>"

      result = Extract.extract(html, type, base_url: "https://example.com/")
      assert result.text =~ "visible"
      refute result.text =~ noise
    end
  end

  defp collect(text, offset, max, acc) do
    {chunk, info} = Extract.page(text, offset, max)

    case info.next_offset do
      nil -> Enum.reverse([chunk | acc])
      next -> collect(text, next, max, [chunk | acc])
    end
  end
end
