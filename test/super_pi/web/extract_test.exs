defmodule SuperPi.Web.ExtractTest do
  use ExUnit.Case, async: true

  alias SuperPi.Web.Extract

  @html """
  <!doctype html>
  <html><head><title>  The   Title </title><style>body{color:red}</style><script>var secret = 1;</script></head>
  <body>
    <header><a href="/">SITE HEADER</a></header>
    <nav><a href="/home">NAV LINK</a></nav>
    <main>
      <h1>Heading One</h1>
      <p>First <strong>bold</strong> and <em>italic</em> with <a href="/docs/a?x=1#frag">a link</a> and <code>code()</code>.</p>
      <ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>
      <ol><li>first</li><li>second</li></ol>
      <blockquote>quoted words</blockquote>
      <pre>line 1
    indented</pre>
      <table><tr><th>Name</th><th>Qty</th></tr><tr><td>pen</td><td>3</td></tr></table>
      <img src="/pic.png" alt="a picture">
      <script>alert('x')</script>
      <a href="mailto:a@b.c">mail</a> <a href="javascript:void(0)">js</a> <a href="https://other.example/p">other</a>
    </main>
    <aside>SIDEBAR</aside>
    <footer>FOOTER TEXT</footer>
  </body></html>
  """

  defp html(body, opts \\ []), do: Extract.extract(body, "text/html; charset=utf-8", [base_url: "https://example.com/base/"] ++ opts)

  describe "HTML to markdown" do
    test "keeps the main content, drops scripts, styles and chrome" do
      r = html(@html)
      assert r.kind == :html
      assert r.title == "The Title"
      assert r.text =~ "# Heading One"
      assert r.text =~ "First **bold** and *italic* with [a link](https://example.com/docs/a?x=1) and `code()`."
      refute r.text =~ "secret"
      refute r.text =~ "alert"
      refute r.text =~ "color:red"
      refute r.text =~ "NAV LINK"
      refute r.text =~ "SIDEBAR"
      refute r.text =~ "FOOTER TEXT"
      refute r.text =~ "SITE HEADER"
    end

    test "renders lists, quotes, code blocks, tables and images" do
      text = html(@html).text
      assert text =~ "- one\n- two"
      assert text =~ "  - nested"
      assert text =~ "1. first\n2. second"
      assert text =~ "> quoted words"
      assert text =~ "```\nline 1\n  indented\n```"
      assert text =~ "| Name | Qty |\n| --- | --- |\n| pen | 3 |"
      assert text =~ "![a picture](https://example.com/pic.png)"
    end

    test "collects absolute http(s) links only, without fragments, deduplicated" do
      links = html(@html).links
      assert "https://example.com/docs/a?x=1" in links
      assert "https://other.example/p" in links
      refute Enum.any?(links, &String.starts_with?(&1, "mailto:"))
      refute Enum.any?(links, &String.starts_with?(&1, "javascript:"))
      refute "https://example.com/home" in links
      assert links == Enum.uniq(links)
    end

    test "caps links at 30" do
      anchors = Enum.map_join(1..80, "", &~s(<a href="/p#{&1}">p#{&1}</a>))
      assert length(html("<main>#{anchors}</main>").links) == 30
    end

    test "the text format keeps structure without markup" do
      text = html(@html, format: "text").text
      assert text =~ "Heading One"
      refute text =~ "# Heading"
      refute text =~ "**"
      refute text =~ "](http"
      assert text =~ "First bold and italic with a link and code()."
    end

    test "the raw format returns the body as text" do
      r = html("<p>x <b>y</b></p>", format: "raw")
      assert r.text == "<p>x <b>y</b></p>"
    end

    test "prefers article over body, and keeps the page header when there is no main" do
      r = html("<body><header><h1>Blog</h1></header><div>junk</div><article><h2>Post</h2><p>Body</p></article></body>")
      assert r.text =~ "## Post"
      refute r.text =~ "junk"

      r = html("<body><header><h1>Blog</h1></header><p>Body</p></body>")
      refute r.text =~ "Blog"
      assert r.text =~ "Body"
    end

    test "keeps the space between inline elements the parser dropped" do
      assert html("<p><b>a</b> <i>b</i> <a href=\"/x\">l</a></p>").text == "**a** *b* [l](https://example.com/x)"
    end

    test "uses the first h1 as the title when there is no title element" do
      assert html("<main><h1>Only Heading</h1><p>x</p></main>").title == "Only Heading"
    end

    test "survives malformed and deeply nested markup" do
      assert %{text: text} = html("<div><p>unclosed <b>bold <i>both</div> tail </span>")
      assert text =~ "unclosed"
      deep = String.duplicate("<div>", 5_000) <> "deep text" <> String.duplicate("</div>", 5_000)
      assert html(deep).text =~ "deep text"
    end

    test "empty and tag-only pages give empty text" do
      assert html("").text == ""
      assert html("<html><body><script>x</script></body></html>").text == ""
    end
  end

  describe "other types" do
    test "JSON is pretty-printed, and invalid JSON stays as text" do
      r = Extract.extract(~s({"a":[1,2],"b":{"c":null}}), "application/json")
      assert r.kind == :json
      assert r.text == ~s({\n  "a": [\n    1,\n    2\n  ],\n  "b": {\n    "c": null\n  }\n})
      assert Extract.extract("{not json", "application/json").text == "{not json"
      assert Extract.extract(~s({"a":1}), "application/vnd.api+json").kind == :json
    end

    test "plain text passes through" do
      r = Extract.extract("a\r\nb", "text/plain")
      assert r.kind == :text
      assert r.text == "a\nb"
    end

    test "kind/2 classifies by header and by sniffing" do
      assert Extract.kind("text/html; charset=UTF-8", nil) == :html
      assert Extract.kind("application/pdf", nil) == :pdf
      assert Extract.kind("image/png", nil) == :binary
      assert Extract.kind("application/zip", nil) == :binary
      assert Extract.kind("application/xml", nil) == :text
      assert Extract.kind("application/atom+xml", nil) == :text
      assert Extract.kind(nil, nil) == :unknown
      assert Extract.kind(nil, "%PDF-1.4 ...") == :pdf
      assert Extract.kind("application/octet-stream", "<!DOCTYPE html><html>") == :html
      assert Extract.kind(nil, <<0, 1, 2, 3>>) == :binary
      assert Extract.kind(nil, "plain words") == :text
    end
  end

  describe "character sets" do
    test "decodes the declared charset" do
      assert Extract.extract(<<"caf", 0xE9>>, "text/plain; charset=iso-8859-1").text == "café"
      assert Extract.extract(<<0x93, "q", 0x94>>, "text/plain; charset=windows-1252").text == "“q”"
      assert Extract.extract("café", "text/plain; charset=utf-8").text == "café"
    end

    test "reads a BOM and an HTML meta charset" do
      utf16 = <<0xFF, 0xFE>> <> :unicode.characters_to_binary("héllo", :utf8, {:utf16, :little})
      assert Extract.extract(utf16, "text/plain").text == "héllo"
      assert Extract.extract(<<0xEF, 0xBB, 0xBF, "bom">>, "text/plain").text == "bom"

      page = <<"<html><head><meta charset=\"iso-8859-1\"></head><body><main>caf", 0xE9, "</main></body></html>">>
      assert Extract.extract(page, "text/html").text == "café"
    end

    test "invalid bytes become the replacement character" do
      text = Extract.extract(<<"ok", 0xFF, 0xFE, "end">>, "text/plain; charset=utf-8").text
      assert String.valid?(text)
      assert text =~ "ok"
      assert text =~ "end"
    end

    test "control characters are removed, tab and newline stay" do
      assert Extract.extract("a\x00b\x07c\td\ne", "text/plain").text == "abc\td\ne"
    end
  end

  describe "paging" do
    test "page/3 counts code points and gives the continuation offset" do
      text = String.duplicate("ä", 10) <> String.duplicate("😀", 10)
      {chunk, info} = Extract.page(text, 0, 15)
      assert Extract.char_count(chunk) == 15
      assert info == %{chars: 20, offset: 0, next_offset: 15, truncated: true}

      {rest, info} = Extract.page(text, 15, 15)
      assert rest == String.duplicate("😀", 5)
      assert %{next_offset: nil, truncated: false, offset: 15} = info
      assert chunk <> rest == text
    end

    test "an offset past the end gives empty text, a negative offset is zero" do
      assert {"", %{chars: 3, offset: 3, truncated: false}} = Extract.page("abc", 99, 10)
      assert {"abc", %{offset: 0}} = Extract.page("abc", -5, 10)
    end

    test "extract/3 applies offset and max_chars" do
      r = Extract.extract(String.duplicate("a", 100), "text/plain", offset: 10, max_chars: 20)
      assert r.text == String.duplicate("a", 20)
      assert %{chars: 100, offset: 10, next_offset: 30, truncated: true} = r
    end
  end
end
