import { expect, test } from 'claude-code/testing'

import { addPath, bandFor, baseOf, dirOf, isSuccess, parsePorcelainZ, relativeTo, summary, without } from './commit'

test('porcelain -z: plain, spaces, unicode and untracked entries', () => {
  expect(parsePorcelainZ(' M src/a.ts\0?? my file.ts\0A  日本語.md\0')).toEqual([
    'src/a.ts',
    'my file.ts',
    '日本語.md',
  ])
})

test('porcelain -z: a rename yields the new path and skips the old one', () => {
  expect(parsePorcelainZ('R  new name.ts\0old.ts\0 M b.ts\0')).toEqual(['new name.ts', 'b.ts'])
  expect(parsePorcelainZ('C  copy.ts\0orig.ts\0')).toEqual(['copy.ts'])
})

test('porcelain -z: a name that merely looks quoted is kept literally (-z never quotes)', () => {
  expect(parsePorcelainZ(' M "odd".ts\0')).toEqual(['"odd".ts'])
})

test('porcelain -z: empty and malformed input yields nothing, never throws', () => {
  expect(parsePorcelainZ('')).toEqual([])
  expect(parsePorcelainZ('\0\0')).toEqual([])
  expect(parsePorcelainZ('garbage')).toEqual([])
  expect(parsePorcelainZ('M\0 M\0xx\0')).toEqual([])
})

test('summary names the count and basenames, fitting what room there is', () => {
  const files = ['/r/a/register.tsx', '/r/b/jump.ts', '/r/c/x.ts']

  expect(summary(files, 200)).toBe('● 3 uncommitted edits: register.tsx, jump.ts, x.ts')
  expect(summary(files, 47)).toBe('● 3 uncommitted edits: register.tsx, jump.ts +1')
  expect(summary(['/r/a.ts'], 200)).toBe('● 1 uncommitted edit: a.ts')
})

test('summary is empty for no files and never exceeds the width for huge lists', () => {
  expect(summary([], 80)).toBe('')
  const files = Array.from({ length: 5000 }, (_, i) => `/r/dir/file-${i}.ts`)

  for (const width of [40, 60, 80, 200]) {
    expect([...summary(files, width)].length).toBeLessThanOrEqual(width)
  }
  expect(summary(files, 80)).toMatch(/\+\d+$/)
})

test('summary degrades to the count when there is no room, and cuts one long name', () => {
  expect(summary(['/r/a.ts', '/r/b.ts'], 10)).toBe('● 2 uncommitted edits')
  expect(() => summary(['/r/a.ts'], 0)).not.toThrow()
  expect(summary(['/r/' + 'n'.repeat(100)], 40)).toMatch(/^● 1 uncommitted edit: n+…$/)
  expect(summary(['/r/日本語.md'], 80)).toBe('● 1 uncommitted edit: 日本語.md')
  expect(summary(['/a/x.ts', '/b/x.ts'], 80)).toBe('● 2 uncommitted edits: x.ts')
})

test('path helpers', () => {
  expect(dirOf('/a/b/c.ts')).toBe('/a/b')
  expect(dirOf('/c.ts')).toBe('/')
  expect(dirOf('c.ts')).toBe('.')
  expect(baseOf('/a/b/c.ts')).toBe('c.ts')
  expect(relativeTo('/repo', '/repo/src/a.ts')).toBe('src/a.ts')
  expect(relativeTo('/repo', '/repository/a.ts')).toBeNull()
  expect(relativeTo('/', '/a.ts')).toBe('a.ts')
  expect(relativeTo('/repo', '/repo')).toBeNull()
})

test('addPath dedups, keeps order, ignores non-strings, does not mutate', () => {
  const before = ['/a']
  const after = addPath(addPath(before, '/b'), '/a')

  expect(after).toEqual(['/a', '/b'])
  expect(before).toEqual(['/a'])
  expect(addPath(after, undefined)).toEqual(['/a', '/b'])
  expect(addPath(after, '')).toEqual(['/a', '/b'])
})

test('without removes only the named paths', () => {
  expect(without(['/a', '/b', '/c'], ['/b', '/z'])).toEqual(['/a', '/c'])
})

test('isSuccess rejects denies and errored results', () => {
  expect(isSuccess({})).toBe(true)
  expect(isSuccess({ deny: 'no' })).toBe(false)
  expect(isSuccess({ isError: true })).toBe(false)
})

test('bandFor: uncommitted files win over the committed mark', () => {
  expect(bandFor(['/r/a.ts'], ['/r/b.ts'], ['/r/b.ts'])).toEqual({ kind: 'uncommitted', files: ['/r/a.ts'] })
})

test('bandFor: the last turn\'s edits, once clean, read as committed', () => {
  expect(bandFor([], ['/r/a.ts', '/r/b.ts'], ['/r/a.ts', '/r/b.ts', '/r/old.ts'])).toEqual({
    kind: 'committed',
    files: ['/r/a.ts', '/r/b.ts'],
  })
})

test('bandFor: no edits last turn, or none of them in the repo, shows nothing', () => {
  expect(bandFor([], [], ['/r/a.ts'])).toBe(null)
  expect(bandFor([], ['/elsewhere/x'], [])).toBe(null)
})

test('summary: the committed form', () => {
  expect(summary(['/r/a.ts', '/r/b.ts'], 80, 'committed')).toBe('✓ 2 edits committed: a.ts, b.ts')
  expect(summary(['/r/a.ts'], 80, 'committed')).toBe('✓ 1 edit committed: a.ts')
  expect(summary(['/r/a.ts'], 10, 'committed')).toBe('✓ 1 edit committed')
})
