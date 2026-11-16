import type { ApiClient } from '@/api/client'

export async function loadBucketSnapshot(api: Pick<ApiClient, 'listBuckets' | 'getBucketConfiguration' | 'getBucketUsage'>, name: string) {
  const [buckets, configuration, usage] = await Promise.allSettled([
    api.listBuckets(), api.getBucketConfiguration(name), api.getBucketUsage(name),
  ])
  return {
    bucket: buckets.status === 'fulfilled' ? buckets.value.find(bucket => bucket.name === name) ?? null : null,
    configuration: configuration.status === 'fulfilled' ? configuration.value : null,
    usage: usage.status === 'fulfilled' ? usage.value : null,
    errors: [buckets, configuration, usage].flatMap(result => result.status === 'rejected' ? [result.reason] : []),
  }
}
