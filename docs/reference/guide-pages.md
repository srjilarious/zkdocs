# Writing Guide Pages

Guide pages are Markdown files listed in the config's `pages` array (see [Site Configuration](page:reference/pages-config)). Beyond standard Markdown and GFM tables, zkdocs supports highlighted code blocks, admonitions and content tabs.

## Code Blocks

Fenced code blocks are highlighted with tree-sitter when the fence names a language zkdocs has a grammar for:

| Fence tag | Language |
|---|---|
| `zig` | Zig |
| `python`, `py` | Python |
| `json` | JSON |

Any other tag, or none, renders the code as plain escaped text.

## Admonitions

An admonition is a callout box in the MkDocs style. The header line is `!!! type "Optional Title"`, and the body is indented four spaces:

```
!!! warning "Before you start"
    Run `zig build` once so the dependencies are fetched.
```

`??? type` instead of `!!! type` makes it collapsible. The types are `note`, `abstract`, `info`, `tip`, `success`, `question`, `warning`, `failure`, `danger`, `bug`, `example` and `quote`; each has its own color and default title.

## Content Tabs

Content tabs show one of several alternatives at a time, such as the same snippet in two languages. Each tab is a `=== "Label"` header with its body indented four spaces, and consecutive headers (with only blank lines between them) form one group:

````
=== "Zig"

    ```zig
    if (eng.inputs.keyboard.pressed(.escape)) eng.quit();
    ```

=== "Python"

    ```python
    if self.keyboard.pressed(Key.ESCAPE):
        self.quit()
    ```
````

The first tab starts selected. Choosing a tab selects the tab with the same label in every group on the page, so a reader who picks "Python" once sees Python everywhere, and the choice is remembered on later pages. A group that has no tab with that label keeps its own selection.

A tab's body is ordinary Markdown: prose, lists, tables and admonitions all work inside one, and a tab holding only a code block shows it edge to edge.
