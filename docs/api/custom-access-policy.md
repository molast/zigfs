# Custom bucket access policy

Bucket configuration `access_policy` accepts and returns `Private`, `Readonly`, `Public`, or `Custom` in both the management API and Admin BFF. The BFF forwards the value without translating it.

PUT `/_admin/v1/buckets/{name}/policy` (BFF: `/api/v1/buckets/{name}/policy`) validates and saves the JSON resource policy and changes the bucket mode to `Custom`. S3 PutBucketPolicy does the same. Custom does not grant the legacy Readonly/Public anonymous permissions: resource-policy evaluation, IAM rules, explicit denies, and Block Public Access still apply.

Deleting a policy changes a Custom bucket back to Private. If another mode was explicitly selected before deletion, it is preserved. PATCH configuration with Custom alone does not create a JSON policy or grant access.

The Admin Custom editor uses PUT policy followed by GET configuration; it no longer changes the mode back to Private. Older buckets with an existing resource policy are recognized by the UI and acquire the persisted Custom mode on the next policy save.

## Storage compatibility and failures

Bucket payload access-policy value 3 represents Custom; existing values 0–2 remain unchanged. Older binaries cannot decode value 3, so downgrading requires removing Custom modes first. Existing metadata remains readable by the new binary.

Mode and resource-policy records are separate writes, not a transaction. The mode is changed before saving the validated document to avoid retaining legacy public grants. If document persistence fails, the request returns an error; Custom mode may remain with the previous policy (or no policy). Retrying the same policy PUT completes the operation. A Custom bucket with no document grants no default anonymous access.
