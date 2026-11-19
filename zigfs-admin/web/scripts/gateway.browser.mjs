// Run only against an isolated test instance; this changes its gateway and creates a test bucket.
const { chromium } = await import(process.env.GATEWAY_PLAYWRIGHT_MODULE || 'playwright-core')
import assert from 'node:assert/strict'
const base = process.env.GATEWAY_TEST_BASE || 'http://127.0.0.1:19001'
const artifacts = process.env.GATEWAY_TEST_ARTIFACTS || '/tmp/zigfs-gateway-browser'
const browser = await chromium.launch({
  executablePath: process.env.GATEWAY_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--no-proxy-server', '--host-resolver-rules=MAP admin.zigfs.home.arpa 127.0.0.1, MAP s3.zigfs.home.arpa 127.0.0.1'],
})
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } })
  const login = await context.request.post(`${base}/api/v1/auth/login`, {
    data: { username: 'admin', password: process.env.GATEWAY_TEST_PASSWORD || 'gateway-qa-password' },
  })
  assert.equal(login.status(), 200, await login.text())
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', e => errors.push(e.message))
  await page.goto(`${base}/settings`)
  await page.getByRole('tab', { name: /Network/ }).click()
  await page.getByRole('tab', { name: 'HTTPS gateway', exact: true }).click()
  await page.locator('#gateway-listen').waitFor()
  await page.locator('#gateway-listen').fill('127.0.0.1:19443')
  await page.locator('#gateway-port').fill('19443')
  await page.getByRole('button', { name: 'Save and prepare HTTPS', exact: true }).click()
  await page.getByText('Candidate ready', { exact: true }).waitFor()
  await page.getByText('Certificate DNS names: admin.zigfs.home.arpa, s3.zigfs.home.arpa', { exact: true }).waitFor()
  await page.getByText(/^Server certificate SHA-256:/).waitFor()
  await page.getByText(/^Automatic leaf renewal:/).waitFor()
  await page.getByRole('button', { name: 'Check server and upstream', exact: true }).click()
  await page.getByText('Local HTTPS and upstream checks passed. Client DNS and certificate trust still require browser verification.', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'Verify from this browser', exact: true }).click()
  await page.getByText('HTTPS verification failed. Check DNS, certificate trust, port mapping and redirects, then retry.', { exact: true }).waitFor()
  assert.equal(await page.getByRole('button', { name: 'Enable configuration', exact: true }).isDisabled(), true)
  await page.screenshot({ path: `${artifacts}/gateway-light.png`, fullPage: true })
  assert.deepEqual(errors, [])
  // Scope TLS bypass to a separate test context for UI success-path coverage.
  // Real chain validation is independently covered by Go HTTPS tests and check.
  const trusted = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1100 } })
  await trusted.addCookies(await context.cookies())
  const p = await trusted.newPage()
  await p.goto(`${base}/settings`)
  await p.getByRole('tab', { name: /Network/ }).click()
  await p.getByRole('tab', { name: 'HTTPS gateway', exact: true }).click()
  await p.getByRole('button', { name: 'Verify from this browser', exact: true }).click()
  await p.getByText('Both HTTPS entries verified from this browser.', { exact: true }).waitFor()
  await p.locator('#gateway-port').fill('19444')
  assert.equal(await p.getByRole('button', { name: 'Enable configuration', exact: true }).isDisabled(), true)
  await p.locator('#gateway-port').fill('19443')
  await p.getByRole('button', { name: 'Enable configuration', exact: true }).click()
  const dialog = p.getByRole('alertdialog')
  await dialog.getByRole('button', { name: /Confirm|确认/ }).click()
  await p.getByText('Gateway and S3 endpoint updated.', { exact: true }).waitFor()
  const settings = await (await trusted.request.get(`${base}/api/v1/settings`)).json()
  assert.equal(settings.s3_public_endpoint, 'https://s3.zigfs.home.arpa:19443')
  await p.getByRole('button', { name: /Switch to dark|Dark mode/ }).click()
  await p.screenshot({ path: `${artifacts}/gateway-dark.png`, fullPage: true })
  const bucket = `gateway-${Date.now()}`
  const created = await trusted.request.post(`${base}/api/v1/buckets`, { data: { name: bucket } })
  assert.ok(created.ok(), await created.text())
  const key = '中文 space+%/nested//file.txt'
  const payload = 'gateway signed object roundtrip'
  for (const method of ['PUT', 'GET', 'HEAD', 'DELETE']) {
    const signed = await trusted.request.post(`${base}/api/v1/objects/presign`, {
      data: { bucket, key, method, expires_seconds: 900 },
    })
    assert.ok(signed.ok(), await signed.text())
    const { url } = await signed.json()
    const result = await p.evaluate(async ({ url, method, payload }) => {
      const response = await fetch(url, { method, ...(method === 'PUT' ? { body: payload } : {}) })
      return { status: response.status, body: await response.text() }
    }, { url, method, payload })
    assert.ok(result.status >= 200 && result.status < 300, JSON.stringify(result))
    if (method === 'GET') assert.equal(result.body, payload)
  }
  // Cleanly disable using the public flow, restoring the old endpoint.
  await p.locator('#gateway-fallback').fill('http://127.0.0.1:19000')
  await p.getByRole('button', { name: 'Disable gateway', exact: true }).click()
  await p.getByRole('alertdialog').getByRole('button', { name: /Confirm|确认/ }).click()
  await p.getByText('Not enabled', { exact: true }).waitFor()
  console.log('Browser checks passed: prepare, trust failure, disabled apply, local check, verified apply, light/dark rendering, disable.')
} finally {
  await browser.close()
}
