# Pinned protocol inputs

`s3.json` is the unmodified Botocore S3 service model downloaded on 2026-11-17 from
https://github.com/boto/botocore/blob/develop/botocore/data/s3/2006-03-01/service-2.json.
Botocore copyright Amazon.com, Inc. or its affiliates; licensed under Apache-2.0.
The full upstream license is in `BOTOCORE-LICENSE.txt`.
The exact source bytes are pinned by SHA256 in `../src/models/provenance.json`.
The upstream branch is mutable; regeneration is offline from this local snapshot.

`management.json` is a JSON conversion of the repository's Management OpenAPI.
From the repository root:

```sh
ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file("docs/api/zigfs-management-v1.openapi.yaml", aliases: true))' > zigfs-cli/models/management.json
python3 zigfs-cli/scripts/generate_catalog.py
python3 zigfs-cli/scripts/generate_management.py
python3 zigfs-cli/scripts/generate_coverage.py
```

Generated runtime models omit documentation but retain referenced request/response
shapes. Management routing additionally reads the current server route table.
Model presence proves neither backend support nor runtime compatibility.
