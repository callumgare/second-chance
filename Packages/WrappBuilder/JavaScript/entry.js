// What SchemaValidator.swift runs in JavaScriptCore: ajv, compiled for JSON
// Schema draft 2020-12, behind two calls. Bundled into
// Sources/WrappBuilder/Resources/ajv.min.js by build.sh; README.md has why.
import Ajv2020 from "ajv/dist/2020";

const ajv = new Ajv2020({
  allErrors: true,
  // Strict mode rejects a schema with an unknown keyword or a mistake in
  // it, so a broken schema fails when it is added, not on a bundle.
  strict: true,
  strictRequired: false,
  allowUnionTypes: true,
});

const compiled = {};

globalThis.Validator = {
  /// Adds a schema (JSON text); others name it by its `$id`.
  addSchema(json) {
    ajv.addSchema(JSON.parse(json));
  },
  /// Checks a document (JSON text) against the schema with that `$id`,
  /// returning `{valid, errors}` as JSON text.
  validate(id, instanceJSON) {
    const validate = compiled[id] || (compiled[id] = ajv.getSchema(id));
    if (!validate) throw new Error("No schema with the id " + id);
    const valid = validate(JSON.parse(instanceJSON));
    return JSON.stringify({ valid, errors: validate.errors || [] });
  },
};
