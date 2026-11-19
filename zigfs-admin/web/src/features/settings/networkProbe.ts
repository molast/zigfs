// Probe from the user's device without sending Admin cookies or credentials.
// Public endpoints may not enable CORS: an opaque response confirms transport
// reachability only, not S3 health or authorization. Gateways expose a CORS-enabled
// probe, so they must also return the expected deployment ID.
export async function checkEndpointFromBrowser(
  endpoint: string,
  signal: AbortSignal,
  deploymentId?: string,
) {
  const url = new URL(endpoint.trim())
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('Invalid probe URL')
  }
  if (deploymentId !== undefined) {
    url.pathname = '/_gateway/probe'
    url.search = ''
    url.hash = ''
  }
  const response = await fetch(url.href, {
    mode: deploymentId === undefined ? 'no-cors' : 'cors',
    credentials: 'omit',
    redirect: deploymentId === undefined ? 'follow' : 'error',
    cache: 'no-store',
    signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
  })
  if (deploymentId !== undefined && (!response.ok || await response.text() !== deploymentId)) {
    throw new Error('Gateway probe did not match the configuration')
  }
}
