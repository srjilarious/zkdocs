; zkdocs simplified Python highlights, adapted from tree-sitter-python's
; queries/highlights.scm (v0.23.6). The upstream file relies on #match?
; predicates (builtins, CONSTANT and Constructor naming) that zkdocs
; doesn't evaluate, and opens with a catch-all `(identifier) @variable`
; that would win every overlap here, since the earliest pattern takes a
; range. Both are dropped; specific patterns come first.

; Comments and strings
(comment) @comment
(string) @string

; Literals
[
  (none)
  (true)
  (false)
] @constant.builtin

[
  (integer)
  (float)
] @number

; Definitions
(function_definition
  name: (identifier) @function)

(class_definition
  name: (identifier) @type)

; Decorators
(decorator) @function
(decorator
  (identifier) @function)

; Calls
(call
  function: (attribute attribute: (identifier) @function.method))
(call
  function: (identifier) @function)

; Type annotations
(type (identifier) @type)

; Keywords
[
  "as"
  "assert"
  "async"
  "await"
  "break"
  "class"
  "continue"
  "def"
  "del"
  "elif"
  "else"
  "except"
  "exec"
  "finally"
  "for"
  "from"
  "global"
  "if"
  "import"
  "lambda"
  "nonlocal"
  "pass"
  "print"
  "raise"
  "return"
  "try"
  "while"
  "with"
  "yield"
  "match"
  "case"
  "and"
  "in"
  "is"
  "not"
  "or"
] @keyword

; Operators
[
  "-"
  "-="
  "!="
  "*"
  "**"
  "**="
  "*="
  "/"
  "//"
  "//="
  "/="
  "&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "->"
  "+="
  "<"
  "<<"
  "<<="
  "<="
  "<>"
  "="
  ":="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "~"
  "@="
] @operator
