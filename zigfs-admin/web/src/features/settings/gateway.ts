export interface GatewayConfig {
  resolution_ip?: string
  listen_address: string
  admin_domain: string
  s3_domain: string
  external_port: number
  certificate_mode: 'local' | 'import'
}

export interface GatewayDeployment {
  id: string
  config: GatewayConfig
  admin_url: string
  s3_url: string
  expires_at: string
  fingerprint: string
  dns_names?: string[]
}

export interface GatewayStatus {
  local_dns?: {
    platform?: string
    supported: boolean
    running: boolean
    resolver_installed: boolean
    address: string
    error?: string
  }
  revision: number
  active: GatewayDeployment | null
  candidate: GatewayDeployment | null
  pending: boolean
  error?: string
  ca_fingerprint?: string
  ca_expires_at?: string
}

// Never send Admin cookies to a probe. This checks the user's DNS and TLS trust,
// not just connectivity from the server running the gateway.
export async function verifyGatewayFromBrowser(deployment: GatewayDeployment) {
  for (const origin of [deployment.admin_url, deployment.s3_url]) {
    const response = await fetch(`${origin}/_gateway/probe`, {
      credentials: 'omit',
      redirect: 'error',
      cache: 'no-store',
      signal: AbortSignal.timeout(15_000),
    })
    if (!response.ok || await response.text() !== deployment.id) {
      throw new Error('Gateway probe did not match the prepared configuration')
    }
  }
}
