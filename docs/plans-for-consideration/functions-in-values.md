# Functions in values

Proposed 2026-11-03. **Not planned yet: build it when a bundle needs it.**
That will be when a Wrappfile has to change a value rather than only read
one: a path in another form for a program's arguments, a name taken from
a path, or a fallback for a value that may be missing and has no schema to
give it a default.

It builds on work proposed with it, which isn't built yet either: values
read through namespaces in `${…}` (`${input.…}`, `${const.…}`,
`${nd.data.…}`), modifiers such as `${x:-default}` removed, and module data
read with its schema's defaults. If that work changes before this is taken
up, this plan changes with it.

## Why

With modifiers gone, a `${…}` can only read a value. Most uses need no
more: an optional field in a module's data reads as its schema's default.
What's left is changing a value, which modifiers did in a fixed way and
functions would do in a way modules can add to:

- **Path forms.** A Wine path given to a program that wants a Mac path, or
  the reverse (`wine.unix-path(…)`, `wine.windows-path(…)`). Path types
  cover a path an instruction takes, so this is only for a path that goes
  into a program's arguments as text.
- **Parts of a path**: its folder or name (`dir(…)`, `name(…)`), for a
  signal matching a log line that names its program, say.
- **A fallback** where nothing can give a default (`default(x, "…")`).

## The shape

```dockerfile
RUN C:/tools/convert.exe "${wine.windows-path(const.saves)}"
WATCH --log=… --contains="Started ${name(program.path)}"
```

- **A call is a name and arguments in parentheses**, inside `${…}`. The
  parentheses tell a call from a reference. Arguments are references or
  quoted strings, and calls can nest.
- **Core functions have bare names** (`default`, `dir`, `name`). A
  module's are named through the module, as its data is
  (`${wine.unix-path(…)}`, `${module.wine.unix-path(…)}`, `${self.f(…)}`).
  The core wins a name clash, with a warning, as elsewhere.
- **They're named in kebab-case**, as everything a Wrappfile names is.
- **They run when planning, and only then.** A wrapp never evaluates one:
  it's given their results, as data.
- **They're pure.** The same arguments give the same result, and they read
  nothing from the Mac or its files, since the result goes into a step's
  text and so into its layer's key.
- **A module's functions are Swift**, declared by the module, so only
  modules with Swift have them.
- **`default` is the one whose first argument may be missing.** Anywhere
  else, a reference to nothing is an error.

## What to call them

A Wrappfile's `FUNCTION` (run with `DO`) and a function in a value would
share a word for two different things: one adds steps, the other works out
a value. The docs need two names, and the syntax keeps them apart already
(`DO x.f` against `${x.f(…)}`). "Value functions", or "helpers", are
candidates.

## Rough phases

1. **The calls and the core functions**: parsed, checked (the function
   exists, its arguments' count), and run while planning.
2. **Modules' functions**, declared in Swift on `BuildModule`, starting
   with the wine module's path forms.

Verify with unit tests of the parser, checker and planner, and of each
function.

## Open questions

1. **The name**, as above.
2. **Types.** Values are text and objects. A function taking or giving a
   number or a list would want those types first.
