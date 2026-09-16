import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { deploy, FUNCTIONS, STAGING_PROJECT, validateEnvironment, validateMigrationNames } from '../../scripts/deploy-staging-db.mjs';

const environment = () => ({
  GITHUB_ACTIONS: 'true',
  GITHUB_REPOSITORY: 'Future-Atlas/sharemarium',
  GITHUB_REF: 'refs/heads/develop',
  SUPABASE_PROJECT_ID: STAGING_PROJECT,
  SUPABASE_DB_PASSWORD: 'test-password-only',
  SUPABASE_ACCESS_TOKEN: 'sbp_fc_test-only-not-a-real-token',
});

test('accepts the approved staging environment', () => {
  assert.doesNotThrow(() => validateEnvironment(environment()));
});

for (const [key, value] of [
  ['SUPABASE_PROJECT_ID', 'jeyxadmkbzgpkveomesz'],
  ['SUPABASE_PROJECT_ID', ''],
  ['SUPABASE_PROJECT_ID', `${STAGING_PROJECT} `],
  ['SUPABASE_PROJECT_ID', `"${STAGING_PROJECT}"`],
  ['GITHUB_REF', 'refs/heads/main'],
  ['GITHUB_REPOSITORY', 'someone/fork'],
  ['GITHUB_ACTIONS', 'false'],
  ['SUPABASE_DB_PASSWORD', ''],
  ['SUPABASE_ACCESS_TOKEN', ''],
  ['SUPABASE_ACCESS_TOKEN', 'sb_publishable_wrong-type'],
  ['SUPABASE_ACCESS_TOKEN', ' sbp_fc_test'],
]) {
  test(`rejects invalid ${key} before any CLI call (${value || 'empty'})`, () => {
    const calls = [];
    assert.throws(() => deploy({
      mode: 'apply', env: { ...environment(), [key]: value },
      run: args => calls.push(args), readLinkedProject: () => STAGING_PROJECT,
    }));
    assert.equal(calls.length, 0);
  });
}

test('plan only links and previews, without applying or deploying functions', () => {
  const calls = [];
  deploy({ mode: 'plan', env: environment(), run: args => calls.push(args), readLinkedProject: () => STAGING_PROJECT });
  assert.deepEqual(calls, [
    ['link', '--project-ref', STAGING_PROJECT, '--yes'],
    ['db', 'push', '--linked', '--include-all', '--dry-run'],
  ]);
});

test('apply previews first and deploys only the three approved staging functions', () => {
  const calls = [];
  deploy({ mode: 'apply', env: environment(), run: args => calls.push(args), readLinkedProject: () => `${STAGING_PROJECT}\n` });
  assert.deepEqual(calls, [
    ['link', '--project-ref', STAGING_PROJECT, '--yes'],
    ['db', 'push', '--linked', '--include-all', '--dry-run'],
    ['db', 'push', '--linked', '--include-all', '--yes'],
    ...FUNCTIONS.map(name => ['functions', 'deploy', name, '--project-ref', STAGING_PROJECT, '--yes']),
  ]);
  assert.ok(!JSON.stringify(calls).includes(environment().SUPABASE_DB_PASSWORD));
  assert.ok(!JSON.stringify(calls).includes(environment().SUPABASE_ACCESS_TOKEN));
});

test('a wrong linked project stops before previewing or applying', () => {
  const calls = [];
  assert.throws(() => deploy({ mode: 'apply', env: environment(), run: args => calls.push(args), readLinkedProject: () => 'production' }));
  assert.equal(calls.length, 1);
});

test('failed preview stops before applying', () => {
  const calls = [];
  assert.throws(() => deploy({
    mode: 'apply', env: environment(), readLinkedProject: () => STAGING_PROJECT,
    run: args => { calls.push(args); if (args.includes('--dry-run')) throw new Error('preview failed'); },
  }));
  assert.equal(calls.length, 2);
});

test('failed migration stops before function deployment', () => {
  const calls = [];
  assert.throws(() => deploy({
    mode: 'apply', env: environment(), readLinkedProject: () => STAGING_PROJECT,
    run: args => { calls.push(args); if (args[0] === 'db' && !args.includes('--dry-run')) throw new Error('migration failed'); },
  }));
  assert.equal(calls.length, 3);
});

test('changed link is checked again before applying', () => {
  const calls = [];
  let reads = 0;
  assert.throws(() => deploy({
    mode: 'apply', env: environment(), run: args => calls.push(args),
    readLinkedProject: () => ++reads === 1 ? STAGING_PROJECT : 'production',
  }));
  assert.equal(calls.length, 2);
});

test('migration filenames reject sync copies and duplicate versions', () => {
  assert.doesNotThrow(() => validateMigrationNames(['20260902110000_example.sql']));
  assert.throws(() => validateMigrationNames([]));
  assert.throws(() => validateMigrationNames(['20260902110000_example 2.sql']));
  assert.throws(() => validateMigrationNames(['20260902110000_one.sql', '20260902110000_two.sql']));
});

test('workflow gates cloud deployment on validation and uses staging, never production', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/supabase-deploy-staging.yaml', import.meta.url), 'utf8');
  const [validation, deployment] = workflow.split('\n  deploy:\n');
  assert.ok(deployment.includes('needs: validate'));
  assert.ok(deployment.includes('name: staging'));
  assert.ok(!workflow.includes('name: production'));
  assert.ok(!validation.includes('${{ secrets.'));
  assert.ok(validation.includes('supabase db reset --local --yes'));
  assert.ok(validation.includes('supabase test db --local'));
  assert.ok(!deployment.includes('db reset'));
  assert.ok(deployment.includes('node scripts/deploy-staging-db.mjs guard'));
  for (const key of ['SUPABASE_PROJECT_ID', 'SUPABASE_DB_PASSWORD', 'SUPABASE_ACCESS_TOKEN']) {
    assert.ok(deployment.includes('${{ secrets.' + key + ' }}'));
  }
});
