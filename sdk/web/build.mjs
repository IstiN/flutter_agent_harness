// Strips types from src/wire-client.ts into dist/wire-client.js so the
// browser example can import the SAME source the conformance runner tests
// (browsers do not run TypeScript; node's type stripping is node-only).
// Requires node >= 22.13 (`node:module`.stripTypeScriptTypes).
import { stripTypeScriptTypes } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

mkdirSync(new URL('./dist/', import.meta.url), { recursive: true });
writeFileSync(
  new URL('./dist/wire-client.js', import.meta.url),
  stripTypeScriptTypes(
    readFileSync(new URL('./src/wire-client.ts', import.meta.url), 'utf8'),
  ),
);
console.log('built dist/wire-client.js');
