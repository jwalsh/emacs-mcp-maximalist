# Elisp Manual: Creating Strings

**Source**: https://www.gnu.org/software/emacs/manual/html_node/elisp/Creating-Strings.html
**Section**: 4.3 Creating Strings
**Fetched**: 2026-03-18

## Full Text

The following functions create strings, either from scratch, or by
putting strings together, or by taking them apart.

### Function: `make-string` count character &optional multibyte

Returns a string made up of *count* repetitions of *character*. If
*count* is negative, an error is signaled.

```elisp
(make-string 5 ?x)
     => "xxxxx"
(make-string 0 ?x)
     => ""
```

If the optional argument *multibyte* is non-`nil`, the function will
produce a multibyte string instead. This is useful when you later need
to concatenate the result with non-ASCII strings.

### Function: `string` &rest characters

Returns a string containing the characters *characters*.

```elisp
(string ?a ?b ?c)
     => "abc"
```

### Function: `substring` string &optional start end

Returns a new string consisting of those characters from *string* in the
range from (and including) the character at index *start* up to (but
excluding) the character at index *end*. The first character is at index
zero.

```elisp
(substring "abcdefg" 0 3)
     => "abc"
(substring "abcdefg" -3 -1)
     => "ef"
(substring "abcdefg" -3 nil)
     => "efg"
```

When `nil` is used for *end*, it stands for the length of the string.

### Function: `substring-no-properties` string &optional start end

Works like `substring` but discards all text properties from the value.

### Function: `concat` &rest sequences

Returns a string consisting of the characters in the arguments. The
arguments may be strings, lists of numbers, or vectors of numbers.

```elisp
(concat "abc" "-def")
     => "abc-def"
(concat "abc" (list 120 121) [122])
     => "abcxyz"
(concat "abc" nil "-def")
     => "abc-def"
(concat)
     => ""
```

**Warning**: This function does not always allocate a new string. Callers
are advised not to rely on the result being a new string nor on it being
`eq` to an existing string. Mutating the returned value may inadvertently
change another string or raise an error.

### Function: `split-string` string &optional separators omit-nulls trim

Splits *string* into substrings based on the regular expression
*separators*. Each match for *separators* defines a splitting point.

If *separators* is `nil`, the default is `split-string-default-separators`
and the function behaves as if *omit-nulls* were `t`.

```elisp
(split-string "  two words ")
     => ("two" "words")
(split-string "Soup is good food" "o")
     => ("S" "up is g" "" "d f" "" "d")
(split-string "Soup is good food" "o" t)
     => ("S" "up is g" "d f" "d")
```

### Function: `string-clean-whitespace` string

Collapses stretches of whitespace to a single space, and removes all
whitespace from the start and end of *string*.

### Function: `string-trim-left` string &optional regexp

Removes the leading text matching *regexp* (default `"[ \t\n\r]+"`) from *string*.

### Function: `string-trim-right` string &optional regexp

Removes the trailing text matching *regexp* (default `"[ \t\n\r]+"`) from *string*.

### Function: `string-trim` string &optional trim-left trim-right

Removes leading text matching *trim-left* and trailing text matching
*trim-right* from *string*. Both regexps default to `"[ \t\n\r]+"`.

### Function: `string-fill` string width

Attempts to word-wrap *string* so that it displays with lines no wider
than *width*. Filling is done on whitespace boundaries only.

### Function: `string-limit` string length &optional end coding-system

If *string* is shorter than *length* characters, returns it as is.
Otherwise returns a substring of the first *length* characters. If
*coding-system* is non-`nil`, limits by bytes instead (never truncating
mid-character).

### Function: `string-lines` string &optional omit-nulls keep-newlines

Splits *string* into a list of strings on newline boundaries.

### Function: `string-pad` string length &optional padding start

Pads *string* to *length* using *padding* (default space). If *start* is
non-`nil`, padding is prepended.

### Function: `string-chop-newline` string

Removes the final newline, if any, from *string*.

---

## Relevance to emacs-mcp-maximalist

### Key functions used by the project

1. **`concat`**: Used extensively in `emcp-stdio.el` and `introspect.el`
   for building JSON strings and s-expressions.

2. **`format`** (documented in separate section): The workhorse for
   building formatted output strings. Used with `%s`, `%S` (prin1
   representation), `%d`, etc.

3. **`string-trim`**: One of the canonical "text-consuming functions"
   that gets exposed as an MCP tool. Also used internally for cleaning
   up `emacsclient` output.

4. **`split-string`**: Used for parsing multi-line output from
   `emacsclient --eval`.

5. **`substring`**: Useful for extracting portions of responses.

### Gotchas

- `concat` may return a shared string -- never mutate its result. This
  is relevant if building response strings that might be modified later.
- `string-trim` and friends are in `subr-x.el` in older Emacs versions.
  In Emacs 28+, they are always available.
- `substring` on vectors returns vectors, not strings -- type matters
  when processing tool arguments.
