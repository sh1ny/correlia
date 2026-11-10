import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const [schemaPath, fixtureRoot, selectedName] = process.argv.slice(2);
if (!schemaPath || !fixtureRoot) {
  console.error('usage: validate.mjs <schema.json> <fixture-root> [case-name]');
  process.exit(64);
}

const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  validateFormats: true,
});
addFormats(ajv);
const validate = ajv.compile(schema);

const manifest = JSON.parse(
  await readFile(path.join(fixtureRoot, 'manifest.json'), 'utf8'),
);
if (!Array.isArray(manifest.cases)) {
  console.error('fixture manifest must contain a cases array');
  process.exit(65);
}
const cases = selectedName
  ? manifest.cases.filter((entry) => entry.name === selectedName)
  : manifest.cases;
if (cases.length === 0) {
  console.error(`fixture case not found: ${selectedName}`);
  process.exit(66);
}

let failed = false;
for (const testCase of cases) {
  const fixture = JSON.parse(
    await readFile(path.join(fixtureRoot, testCase.path), 'utf8'),
  );
  const valid = validate(fixture);
  if (valid !== testCase.valid) {
    failed = true;
    const errors = (validate.errors ?? [])
      .map((error) => `${error.instancePath || '/'} ${error.message}`)
      .join('; ');
    console.error(
      `${testCase.name}: expected ${testCase.valid ? 'valid' : 'invalid'}, got `
      + `${valid ? 'valid' : 'invalid'}${errors ? ` (${errors})` : ''}`,
    );
    continue;
  }
  if (!testCase.valid && testCase.errorPath) {
    const matchingError = (validate.errors ?? []).some(
      (error) =>
        (testCase.errorPath === '/' ||
          error.instancePath === testCase.errorPath) &&
        (testCase.errorProperty === undefined ||
          error.params?.property === testCase.errorProperty ||
          error.params?.additionalProperty === testCase.errorProperty),
    );
    if (!matchingError) {
      failed = true;
      console.error(
        `${testCase.name}: expected an Ajv error at ${testCase.errorPath}`,
      );
    }
  }
}

if (failed) process.exit(1);
console.log(`${cases.length} schema fixture case(s) passed`);
