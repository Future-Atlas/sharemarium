import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = (path) =>
  readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8')

test('subscription UI remains disabled until legal terms are ready', () => {
  const flags = read('lib/config/feature_flags.dart')
  assert.match(
    flags,
    /static const bool subscriptionUiEnabled = false;/,
  )
})

test('account settings hides the entire subscription section behind the release flag', () => {
  const settings = read('lib/screens/account_settings_screen.dart')
  const gate = settings.indexOf('if (FeatureFlags.subscriptionUiEnabled)')
  const section = settings.indexOf("const _SectionTitle('プラン・契約')")
  const screen = settings.indexOf('SubscriptionStatusScreen()')

  assert.ok(gate >= 0)
  assert.ok(section > gate)
  assert.ok(screen > gate)
})
