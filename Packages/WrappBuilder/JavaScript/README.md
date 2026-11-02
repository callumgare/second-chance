# ajv, bundled for JavaScriptCore

Program bundles are checked against their JSON Schema by
[ajv](https://ajv.js.org), run in JavaScriptCore (`SchemaValidator.swift`).
Of the validators tried, it was the only one that supports all of draft
2020-12, takes other schemas by `$id` with no network, and says what is
wrong clearly enough to reword for a bundle's author. JavaScriptCore is part
of macOS, so the cost is about 140 KB of script.

`entry.js` is all of our JavaScript: it gives Swift two calls,
`Validator.addSchema` and `Validator.validate`. `build.sh` bundles it with
ajv, at the versions `package-lock.json` pins, and writes the result to
`Sources/WrappBuilder/Bundles/AjvScript.swift` as a Swift string, with the
licence of every package inside at its head. A string rather than a
resource, so the package needs no resource bundle (whose accessor is
main-actor-only under the package's settings, and which every app linking
the package would have to carry). The output is committed, so building
Second Chance needs no Node.

To update ajv, change the versions in `package.json`, run
`npm install --package-lock-only --ignore-scripts` here, then `./build.sh`,
and check `swift test --package-path Packages/WrappBuilder` still passes.
