import { checkEndpointFromBrowser } from './networkProbe'

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
    await checkEndpointFromBrowser(origin, new AbortController().signal, deployment.id)
  }
}
