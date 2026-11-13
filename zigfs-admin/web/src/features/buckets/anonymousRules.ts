export type Access = 'readonly' | 'writeonly' | 'readwrite'
export type AccessRule = { id: string; prefix: string; access: Access }
type Statement = Record<string, unknown>
type Policy = { Version: string; Statement: Statement[]; [key: string]: unknown }
const marker = 'ZigFSAnonymous'
export function parsePolicy(document: string): Policy {
  const policy = document ? JSON.parse(document) : { Version: '2012-10-17', Statement: [] }
  if (!policy || !Array.isArray(policy.Statement)) throw new Error('Invalid policy')
  return policy
}
export function statements(bucket: string, rule: AccessRule, legacy = false): Statement[] {
  const actions: string[] = []
  if (rule.access !== 'writeonly') actions.push('s3:GetObject', 's3:GetObjectVersion')
  if (rule.access !== 'readonly') {
    actions.push('s3:PutObject', 's3:DeleteObject')
    if (!legacy) actions.push('s3:DeleteObjectVersion', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts')
  }
  const result: Statement[] = [{ Sid: `${marker}${rule.id}Objects`, Effect: 'Allow', Principal: '*', Action: actions, Resource: `arn:aws:s3:::${bucket}/${rule.prefix}*` }]
  if (rule.access !== 'writeonly') result.push({ Sid: `${marker}${rule.id}List`, Effect: 'Allow', Principal: '*', Action: ['s3:ListBucket'], Resource: `arn:aws:s3:::${bucket}`, Condition: { StringLike: { 's3:prefix': [`${rule.prefix}*`] } } })
  if (!legacy && rule.access !== 'readonly') result.push({ Sid: `${marker}${rule.id}Uploads`, Effect: 'Allow', Principal: '*', Action: ['s3:ListBucketMultipartUploads'], Resource: `arn:aws:s3:::${bucket}`, Condition: { StringLike: { 's3:prefix': [`${rule.prefix}*`] } } })
  return result
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).sort().join(',')}]`
  if (value && typeof value === 'object') return JSON.stringify(Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)])))
  return JSON.stringify(value)
}
export function accessRules(policy: Policy, bucket: string): AccessRule[] {
  const rules: AccessRule[] = []
  for (const item of policy.Statement) {
    const match = typeof item.Sid === 'string' && item.Sid.match(/^ZigFSAnonymous([a-f0-9]+)Objects$/)
    const resource = `arn:aws:s3:::${bucket}/`
    if (!match || typeof item.Resource !== 'string' || !item.Resource.startsWith(resource) || !item.Resource.endsWith('*')) continue
    const prefix = item.Resource.slice(resource.length, -1)
    for (const access of ['readonly', 'writeonly', 'readwrite'] as const) {
      const rule = { id: match[1], prefix, access }
      const expected = statements(bucket, rule)
      const actual = policy.Statement.filter(s => s.Sid === `${marker}${rule.id}Objects` || s.Sid === `${marker}${rule.id}List` || s.Sid === `${marker}${rule.id}Uploads`)
      if (canonical(actual) === canonical(expected) || canonical(actual) === canonical(statements(bucket, rule, true))) { rules.push(rule); break }
    }
  }
  return rules
}
export function updateRule(policy: Policy, bucket: string, id: string, rule?: AccessRule): Policy {
  const current = accessRules(policy, bucket)
  const replaced = current.filter(value => value.id === id || (rule && value.prefix === rule.prefix))
  const removedSids = new Set(replaced.flatMap(value => [`${marker}${value.id}Objects`, `${marker}${value.id}List`, `${marker}${value.id}Uploads`]))
  const kept = policy.Statement.filter(statement => !removedSids.has(statement.Sid as string))
  const savedId = current.find(value => rule && value.prefix === rule.prefix)?.id ?? id
  return { ...policy, Statement: [...kept, ...(rule ? statements(bucket, { ...rule, id: savedId }) : [])] }
}
