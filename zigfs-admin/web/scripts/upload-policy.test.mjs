import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'

const source = readFileSync(new URL('../src/features/objects/upload-policy.ts', import.meta.url), 'utf8')
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext } }).outputText
const { chooseUploadPlan, MAX_OBJECT_SIZE } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`)
const cases = JSON.parse(readFileSync(new URL('../../../docs/validation/upload-policy-cases.json', import.meta.url)))
for (const example of cases) {
  const plan = chooseUploadPlan(example.size)
  assert.deepEqual(plan, {
    multipart: example.multipart,
    partSize: example.part_size,
    concurrency: example.concurrency,
  })
  assert.ok(Math.ceil(example.size / plan.partSize) <= 10000)
}
assert.equal(chooseUploadPlan(128 * 1024 * 1024, 2).partSize, 64 * 1024 * 1024)
for (const invalid of [-1, NaN, MAX_OBJECT_SIZE + 1]) {
  assert.throws(() => chooseUploadPlan(invalid))
}
console.log(`Admin upload policy: ${cases.length} shared boundary cases passed`)
