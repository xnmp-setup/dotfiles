// Reads git through $.process. Every failure (git missing, not a repo, a
// timeout) answers null, never throws.

import type { EngineInterface } from 'claude-code'

import { dirOf, parsePorcelainZ, relativeTo } from './commit'

const TIMEOUT_MS = 5000

async function git($: EngineInterface, dir: string, args: readonly string[]): Promise<string | null> {
  try {
    const ran = await $.process.run(['git', '--no-optional-locks', '-C', dir, ...args], {
      timeoutMs: TIMEOUT_MS,
    })

    return ran.exitCode === 0 ? ran.stdout : null
  } catch {
    return null
  }
}

async function topLevel($: EngineInterface, dir: string): Promise<string | null> {
  const top = ((await git($, dir, ['rev-parse', '--show-toplevel'])) ?? '').trim()

  return top === '' ? null : top
}

export type Check = {
  // Tracked files that git checked and found clean.
  clean: string[]
  // Tracked files git checked and found uncommitted (absolute).
  dirty: string[]
}

/** Checks the tracked files that lie in the session's repo; null when that cannot be told. */
export async function checkTracked(
  $: EngineInterface,
  cwd: string,
  tracked: readonly string[],
): Promise<Check | null> {
  const repo = await topLevel($, cwd)

  if (repo === null) {
    return null
  }
  const dirs = [...new Set(tracked.map(dirOf))]
  const results = await Promise.all(dirs.map(dir => topLevel($, dir)))
  const tops = new Map(dirs.map((dir, i) => [dir, results[i] ?? null]))
  // A file's own repo, resolved through its directory, is the session's repo;
  // the path prefix test keeps the answer in the repo's own spelling.
  const here = tracked.filter(f => tops.get(dirOf(f)) === repo)

  if (here.length === 0) {
    return { clean: [], dirty: [] }
  }
  const status = await git($, repo, ['status', '--porcelain=v1', '-z', '--', ...here])

  if (status === null) {
    return null
  }
  const listed = new Set(parsePorcelainZ(status))
  // A file outside the repo's own spelling of its path (a symlinked checkout)
  // cannot be matched, so it is neither clean nor dirty: left tracked, not shown.
  const known = here.filter(f => relativeTo(repo, f) !== null)
  const isListed = (f: string) => listed.has(relativeTo(repo, f) ?? '')

  return { dirty: known.filter(isListed), clean: known.filter(f => !isListed(f)) }
}

/** The session repo's HEAD commit, or null (no git, no repo, no commit yet). */
export async function headOf($: EngineInterface, cwd: string): Promise<string | null> {
  const sha = ((await git($, cwd, ['rev-parse', '--verify', '--quiet', 'HEAD'])) ?? '').trim()

  return sha === '' ? null : sha
}

/**
 * Of `files` (absolute), those a commit after `base` touched: `base..HEAD`,
 * or every commit up to HEAD when the repo had none at `base` (null). Empty
 * when git can't tell (no repo, `base` gone after a rewrite).
 */
export async function committedSince(
  $: EngineInterface,
  cwd: string,
  base: string | null,
  files: readonly string[],
): Promise<string[]> {
  const repo = await topLevel($, cwd)

  if (repo === null || files.length === 0) {
    return []
  }
  const inRepo = files.filter(f => relativeTo(repo, f) !== null)
  const range = base === null ? 'HEAD' : `${base}..HEAD`
  const out = inRepo.length === 0 ? null : await git($, repo, ['log', '--format=', '--name-only', '-z', range, '--', ...inRepo])

  if (out === null) {
    return []
  }
  const touched = new Set(out.split(/[\0\n]/).filter(p => p !== ''))

  return inRepo.filter(f => touched.has(relativeTo(repo, f) ?? ''))
}
