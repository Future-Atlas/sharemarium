import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const STAGING_PROJECT = 'wpoigmywpewrrbudqhgh';
export const FUNCTIONS = ['session-guard', 'delete-account', 'admin-delete-account', 'billing-checkout', 'billing-webhook'];

export function validateEnvironment(env) {
  if (env.GITHUB_ACTIONS !== 'true' ||
      env.GITHUB_REPOSITORY !== 'Future-Atlas/sharemarium' ||
      env.GITHUB_REF !== 'refs/heads/develop') {
    throw new Error('Deployment is restricted to develop in the Sharemarium GitHub repository.');
  }
  // Compare exactly: do not silently remove quotes or whitespace from a wrong ID.
  if (env.SUPABASE_PROJECT_ID !== STAGING_PROJECT) {
    throw new Error('SUPABASE_PROJECT_ID must match the approved staging project.');
  }
  for (const name of ['SUPABASE_DB_PASSWORD', 'SUPABASE_ACCESS_TOKEN']) {
    const value = env[name];
    if (typeof value !== 'string' || value.trim() === '') {
      throw new Error(`${name} is missing. Configure it in the staging environment secrets.`);
    }
  }
  const token = env.SUPABASE_ACCESS_TOKEN;
  if (token !== token.trim() || !token.startsWith('sbp_')) {
    throw new Error('SUPABASE_ACCESS_TOKEN must be a Supabase personal access token, without surrounding whitespace.');
  }
}

export function validateMigrationNames(names) {
  if (names.length === 0) throw new Error('No migrations found.');
  const versions = new Set();
  for (const name of names) {
    const match = /^(\d{14})_[a-z0-9_]+\.sql$/.exec(name);
    if (!match || versions.has(match[1])) {
      throw new Error('Invalid or duplicate migration filename. Resolve sync copies before deployment.');
    }
    versions.add(match[1]);
  }
}

export function checkFiles(cwd = process.cwd()) {
  const required = [
    'supabase/config.toml',
    'supabase/seed.sql',
    ...FUNCTIONS.map(name => `supabase/functions/${name}/index.ts`),
  ];
  for (const file of required) {
    if (!existsSync(resolve(cwd, file))) throw new Error(`Required file is missing: ${file}`);
  }
  validateMigrationNames(readdirSync(resolve(cwd, 'supabase/migrations')));
}

export function deploy({
  mode,
  env = process.env,
  cwd = process.cwd(),
  run = (args) => execFileSync('supabase', args, { cwd, env, stdio: 'inherit' }),
  readLinkedProject = () => readFileSync(resolve(cwd, 'supabase/.temp/project-ref'), 'utf8'),
}) {
  if (!['plan', 'apply'].includes(mode)) throw new Error('Choose plan or apply.');
  validateEnvironment(env);
  const checkTarget = () => {
    validateEnvironment(env);
    if (readLinkedProject().trim() !== STAGING_PROJECT) {
      throw new Error('Linked project does not match staging. No further operations allowed.');
    }
  };

  // Password is read from SUPABASE_DB_PASSWORD, never passed as a CLI argument.
  run(['link', '--project-ref', STAGING_PROJECT, '--yes']);
  checkTarget();
  // include-all also handles an older migration added after newer migrations.
  run(['db', 'push', '--linked', '--include-all', '--dry-run']);
  if (mode === 'plan') return;

  checkTarget();
  // Never reset a linked/cloud database. Only apply pending migrations.
  run(['db', 'push', '--linked', '--include-all', '--yes']);
  for (const name of FUNCTIONS) {
    checkTarget();
    run(['functions', 'deploy', name, '--project-ref', STAGING_PROJECT, '--yes']);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const mode = process.argv[2];
    if (mode === 'check') {
      checkFiles();
    } else if (mode === 'guard') {
      validateEnvironment(process.env);
    } else {
      checkFiles();
      deploy({ mode });
    }
  } catch (error) {
    // Do not dump the child process object: it may contain authentication data.
    const message = typeof error.status === 'number'
      ? 'Supabase command failed; deployment stopped. Review the preceding CLI output (do not enable --debug).'
      : error.message;
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  }
}
