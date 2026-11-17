// Pure decisions for uncommitted-edits: no engine, no I/O.

/** Whether a tool result means the call went through. */
export const isSuccess = (ran: { deny?: unknown; isError?: unknown }): boolean =>
  ran.deny === undefined && ran.isError !== true

/** Adds a path, keeping first-seen order and no duplicates. Ignores blanks. */
export const addPath = (paths: readonly string[], path: unknown): string[] =>
  typeof path !== 'string' || path === '' || paths.includes(path) ? [...paths] : [...paths, path]

export const dirOf = (path: string): string => {
  const i = path.lastIndexOf('/')

  return i < 0 ? '.' : i === 0 ? '/' : path.slice(0, i)
}

export const baseOf = (path: string): string => path.slice(path.lastIndexOf('/') + 1)

/**
 * Paths from `git status --porcelain=v1 -z`: entries are `XY path` split by NUL;
 * a rename or copy is followed by one more entry, the old path, which is
 * skipped. -z never quotes, so names are taken literally. Malformed entries are
 * skipped.
 */
export function parsePorcelainZ(out: string): string[] {
  const parts = out.split('\0')
  const paths: string[] = []

  for (let i = 0; i < parts.length; i++) {
    const entry = parts[i] ?? ''

    if (entry.length < 4 || entry[2] !== ' ') {
      continue
    }
    const isMove = 'RC'.includes(entry[0] ?? '') || 'RC'.includes(entry[1] ?? '')
    paths.push(entry.slice(3))

    if (isMove) {
      i += 1
    }
  }

  return paths
}

/** `path` relative to `dir`, or null when it does not lie under it. */
export function relativeTo(dir: string, path: string): string | null {
  const prefix = dir === '/' ? '/' : `${dir}/`

  return path.startsWith(prefix) && path.length > prefix.length ? path.slice(prefix.length) : null
}

/** Paths of `paths` that are not in `drop`, order kept. */
export const without = (paths: readonly string[], drop: readonly string[]): string[] =>
  paths.filter(p => !drop.includes(p))

export type Kind = 'uncommitted' | 'committed'

/**
 * `● 3 uncommitted edits: a.ts, b.ts +1` (or `✓ 2 edits committed: …`) in at
 * most `width` characters: basenames, deduplicated, as many as fit. Empty
 * when there are no files. Counts code points, so wide (CJK) names may run a
 * little over on screen.
 */
/**
 * What the band shows: the uncommitted files if any, else the last turn's
 * edits once git shows every one of them committed. A last turn with no
 * edits in the repo shows nothing.
 */
export function bandFor(
  dirty: readonly string[],
  lastTurn: readonly string[],
  clean: readonly string[],
): { kind: Kind; files: readonly string[] } | null {
  if (dirty.length > 0) {
    return { kind: 'uncommitted', files: dirty }
  }
  const committed = lastTurn.filter(f => clean.includes(f))

  return committed.length > 0 ? { kind: 'committed', files: committed } : null
}

export function summary(files: readonly string[], width: number, kind: Kind = 'uncommitted'): string {
  if (files.length === 0) {
    return ''
  }
  const names = [...new Set(files.map(baseOf).filter(n => n !== ''))]
  const noun = files.length === 1 ? 'edit' : 'edits'
  const prefix =
    kind === 'uncommitted' ? `● ${files.length} uncommitted ${noun}` : `✓ ${files.length} ${noun} committed`
  const len = (s: string) => [...s].length

  if (names.length === 0 || len(prefix) >= width) {
    return prefix
  }
  const head = `${prefix}: `
  const suffix = (rest: number) => (rest > 0 ? ` +${rest}` : '')
  let used = len(head)
  let best = 0

  names.forEach((name, i) => {
    used += len(name) + (i > 0 ? 2 : 0)

    if (used + len(suffix(names.length - i - 1)) <= width) {
      best = i + 1
    }
  })

  if (best > 0) {
    return head + names.slice(0, best).join(', ') + suffix(names.length - best)
  }
  const room = Math.max(1, width - len(head))
  const first = [...(names[0] ?? '')]

  return head + (first.length > room ? first.slice(0, room - 1).join('') + '…' : first.join(''))
}
