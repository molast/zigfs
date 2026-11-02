import assert from 'node:assert/strict'
import { test } from 'node:test'
import { appRoutePath, createAppRoute, parseAppRoute } from '../src/routes.ts'

test('root and removed overview routes open the object browser', () => {
  assert.equal(parseAppRoute('/').view, 'buckets')
  assert.equal(parseAppRoute('/dashboard').view, 'buckets')
  assert.equal(appRoutePath(createAppRoute('buckets')), '/buckets')
})

test('bucket configuration and object paths remain available', () => {
  assert.deepEqual(parseAppRoute('/buckets/photos', '?view=configuration'), {
    view: 'bucket-detail',
    bucket: 'photos',
    prefix: '',
  })
  assert.deepEqual(parseAppRoute('/buckets/photos/2026/trip/'), {
    view: 'objects',
    bucket: 'photos',
    prefix: '2026/trip/',
  })
  assert.equal(appRoutePath(createAppRoute('objects', 'photos', '2026/trip/')), '/buckets/photos/2026/trip/')
})
