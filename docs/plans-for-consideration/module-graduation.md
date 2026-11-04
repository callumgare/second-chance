# Module graduation

Proposed 2026-11-04. **Not planned yet: build it when a module someone else
wrote is to become one Second Chance ships and looks after.**

It builds on work proposed with it, which isn't built yet either:

- module programs: a module someone adds carrying a program that carries
  out its instructions, talking to the build over JSON-RPC on its stdin and
  stdout;
- `WrappModuleKit`, the library that program is written with, whose
  `ModuleExecutor` and `StepContext` are the same API a shipped module's
  executor is written against;
- executors as Swift packages, one library target per module, with a
  module program being that library plus a one-line executable target.

If that work changes before this is taken up, this plan changes with it.

## Why

A module's executor runs either inside Second Chance (a shipped module's)
or as a program of its own (one someone adds), with one API either way.
That makes taking a module over a move rather than a rewrite. But the move
still has steps that are easy to get wrong: the module's id, its release
numbers, and the text it shows. Nothing needs them until there's a module
to take over, so they're left until then.

## Taking a module over

1. **Copy its library target** into `Packages/ModuleExecutors/` as
   `<Name>Executor`, leaving its `main.swift` behind, and register it in
   the native table (`BuildModules.native`) under its module id.
2. **Point its `module.yaml` at the Swift**: `program:` becomes `native:`,
   and the folder is copied into `Modules/`, without `bin/`.
3. **Keep its id.** Bundles say `USE someone/gog`, so it keeps its
   namespaced id rather than being renamed. The schema's rule that a
   shipped module's id is one name becomes "one name, or a namespaced id
   the module graduated with". A shipped module already wins over an
   added one with its id, so someone who imported it gets ours, with the
   warning that Second Chance's own is used.
4. **Carry its release line on.** Added releases of a shipped id are
   refused, because two parties would give out the same numbers.
   Graduation hands the line over:
   - our first release is one above the community's last, and is a new
     release even if nothing else changed, since `program:` becoming
     `native:` is a change;
   - `Modules/releases.json` takes in the releases it had, with their
     hashes, so a wrapp whose lock names an earlier one still matches it
     for updates;
   - after that, a release of that id from outside isn't imported.
5. **Localise its text.** A module program's text is its own English. A
   shipped module's is `String(localized:)`, in both apps' string
   catalogues.
6. **Lay it out for stamped revisions**, if it's one whose layers sit
   under much else, as a shipped executor would be.

Its layers are made fresh once, since its steps' keys had its program's
hash in them and now have its stamped revision. That's the safe default,
as the code now runs differently.

## Tooling

`sc module graduate <folder>` would carry out steps 1 to 4 and print a
checklist of 5 and 6, which need a person.

## Testing

Graduate a fixture module (a Swift program built with `WrappModuleKit`)
on a branch, and check the graduated executor behaves as the program did:
the same test bundle builds with it compiled in, its steps make the same
tree and emit the same events, and a bundle naming its namespaced id
resolves to it. Behaviour, not identical files, since steps 5 and 6 change
the code.
