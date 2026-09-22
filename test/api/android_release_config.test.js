import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8')

test('Android production identity is consistent', () => {
  const gradle = read('android/app/build.gradle.kts')
  const manifest = read('android/app/src/main/AndroidManifest.xml')
  const activity = read('android/app/src/main/kotlin/com/futureatlas/sharemarium/MainActivity.kt')

  assert.match(gradle, /namespace = "com\.futureatlas\.sharemarium"/)
  assert.match(gradle, /applicationId = "com\.futureatlas\.sharemarium"/)
  assert.match(activity, /^package com\.futureatlas\.sharemarium/m)
  assert.match(manifest, /android:label="Sharemarium"/)
  assert.equal(
    existsSync(new URL('../../android/app/src/main/kotlin/com/example/flutter_application_1/MainActivity.kt', import.meta.url)),
    false,
  )
})

test('Android release configuration never falls back to debug signing', () => {
  const gradle = read('android/app/build.gradle.kts')

  assert.match(gradle, /rootProject\.file\("key\.properties"\)/)
  assert.match(gradle, /signingConfigs/)
  assert.match(gradle, /getByName\("release"\)/)
  assert.doesNotMatch(gradle, /getByName\("debug"\)/)
})

test('Android signing secrets are excluded from Git', () => {
  const gitignore = read('.gitignore')
  const example = read('android/key.properties.example')

  assert.match(gitignore, /\/android\/key\.properties/)
  assert.match(gitignore, /\*\*\/\*\.jks/)
  assert.match(gitignore, /\*\*\/\*\.keystore/)
  for (const key of ['storePassword', 'keyPassword', 'keyAlias', 'storeFile']) {
    assert.match(example, new RegExp(`^${key}=`, 'm'))
  }
})
