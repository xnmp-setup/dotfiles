import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'uncommitted-edits',
  component: 'AbovePrompt',
  requestId: 'band',
  surface: 'terminal',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 6,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 6 },
    view: {},
  },
} as const

// A fake git for a repo at /repo with HEAD `abc`: `dirty` is what `status`
// reports, `logged` what `log` lists as touched by commits since then.
const fakeGit = (dirty: string, logged = '') => (argv: readonly string[]) => {
  const args = argv.slice(argv.indexOf('-C') + 2)
  const out = (stdout: string, exitCode = 0) => ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })

  switch (args[0]) {
    case 'rev-parse':
      return args.includes('--show-toplevel') ? out('/repo\n') : out('abc\n')
    case 'status':
      return out(dirty)
    case 'log':
      return out(logged)
    default:
      return out('', 1)
  }
}

async function editAndFinishTurn($: any, on: any, dirty: string, logged = '') {
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => fakeGit(dirty, logged)(e.argv))
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', () => ({ text: '' }))
  await $.tool.call({ tool: 'Edit', file_path: '/repo/src/register.tsx', old_string: 'a', new_string: 'b' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
}

// The git refresh runs after the turn ends; let it settle.
declare const setTimeout: (fn: () => void, ms: number) => unknown
const settle = (_: unknown) => new Promise<void>(done => setTimeout(done, 20))

test('after an edit and a turn, the band says what is uncommitted', async ($, on) => {
  await editAndFinishTurn($, on, ' M src/register.tsx\0')
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /^●$/ }))?.text).toBe('●')
  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(' 1 uncommitted edit: register.tsx')
  await ui.unmount()
})

test('when a commit took the last turn\'s edits, the band says so', async ($, on) => {
  await editAndFinishTurn($, on, '', 'src/register.tsx\0')
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /^✓$/ }))?.text).toBe('✓')
  expect((await ui.find({ type: 'Text', text: /committed/ }))?.text).toBe(' 1 edit committed: register.tsx')
  expect(await ui.find({ type: 'Text', text: /uncommitted/ })).toBeUndefined()
  await ui.unmount()
})

test('an edit undone again is clean but not committed: no mark', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await editAndFinishTurn($, on, '', '')
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect(await ui.find({ type: 'Text', text: /committed/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /engine/ })).toBeDefined()
  await ui.unmount()
})

test('a later turn with no edits clears the committed mark', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await editAndFinishTurn($, on, '', 'src/register.tsx\0')
  await settle($)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't2', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect(await ui.find({ type: 'Text', text: /committed/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /engine/ })).toBeDefined()
  await ui.unmount()
})

// Two repos: the session's at /repo and another at /other, each with its own status.
const twoRepos = (statusByRepo: Record<string, string>) => (argv: readonly string[]) => {
  const dir = argv[argv.indexOf('-C') + 1] ?? ''
  const args = argv.slice(argv.indexOf('-C') + 2)
  const repo = dir.startsWith('/other') ? '/other' : '/repo'
  const out = (stdout: string, exitCode = 0) => ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })

  switch (args[0]) {
    case 'rev-parse':
      return args.includes('--show-toplevel') ? out(`${repo}\n`) : out('abc\n')
    case 'status':
      return out(statusByRepo[repo] ?? '')
    default:
      return out('', 1)
  }
}

test('an uncommitted edit in a repo other than the session\'s shows, labelled with that repo', async ($, on) => {
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) =>
    twoRepos({ '/other': ' M src/b.ts\0' })(e.argv),
  )
  on('tool.call', () => ({ result: {} }))
  on('turn.complete', () => ({ text: '' }))
  await $.tool.call({ tool: 'Edit', file_path: '/repo/src/a.ts', old_string: 'a', new_string: 'b' })
  await $.tool.call({ tool: 'Edit', file_path: '/other/src/b.ts', old_string: 'a', new_string: 'b' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(' 1 uncommitted edit: other:b.ts')
  await ui.unmount()
})

const ran = (stdout: string, exitCode = 0) => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

test('a file a Bash command changed during the turn shows as uncommitted', async ($, on) => {
  // The repo-wide snapshot (-uall) sees nothing at turn start, then the Bash edit.
  let snapshots = 0
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    const args = e.argv.slice(e.argv.indexOf('-C') + 2)

    if (args[0] === 'rev-parse') {
      return args.includes('--show-toplevel') ? ran('/repo\n') : ran('abc\n')
    }
    if (args[0] === 'status' && args.includes('-uall')) {
      snapshots += 1

      return ran(snapshots === 1 ? ' M old.ts\0' : ' M old.ts\0 M src/bashed.ts\0')
    }

    return args[0] === 'status' ? ran(' M src/bashed.ts\0') : ran('', 1)
  })
  on('turn.start', () => ({ turnId: 't1' }))
  on('turn.complete', () => ({ text: '' }))
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  // old.ts was already uncommitted before the turn: not Claude's.
  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(' 1 uncommitted edit: bashed.ts')
  await ui.unmount()
})

test('after git times out once, it is not run again until the session restarts', async ($, on) => {
  let runs = 0
  let toasts = 0
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', () => {
    runs += 1
    throw new Error('timed out')
  })
  on('turn.start', () => ({ turnId: 't' }))
  on('turn.complete', () => ({ text: '' }))
  on('ui.toast', () => {
    toasts += 1

    return { value: undefined }
  })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await settle($)
  const afterFirst = runs

  await $.turn.start({ text: 'go', turnId: 't2' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't2', reason: 'answer' })
  await settle($)

  expect(afterFirst).toBeGreaterThan(0)
  expect(runs).toBe(afterFirst)
  expect(toasts).toBe(1)
})

test('a Bash edit from an earlier turn still shows after later turns change nothing', async ($, on) => {
  // Turn 1 starts clean and ends with the Bash edit; every later snapshot is the same.
  let snapshots = 0
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    const args = e.argv.slice(e.argv.indexOf('-C') + 2)

    if (args[0] === 'rev-parse') {
      return args.includes('--show-toplevel') ? ran('/repo\n') : ran('abc\n')
    }
    if (args[0] === 'status' && args.includes('-uall')) {
      snapshots += 1

      return ran(snapshots === 1 ? '' : ' M src/bashed.ts\0')
    }

    return args[0] === 'status' ? ran(' M src/bashed.ts\0') : ran('', 1)
  })
  on('turn.start', () => ({ turnId: 't' }))
  on('turn.complete', () => ({ text: '' }))

  for (const turnId of ['t1', 't2', 't3']) {
    await $.turn.start({ text: 'go', turnId })
    await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId, reason: 'answer' })
    await settle($)
  }

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(' 1 uncommitted edit: bashed.ts')
  await ui.unmount()
})

test('an already-uncommitted file that a Bash command writes again shows as uncommitted', async ($, on) => {
  // git status is the same at both ends of the turn; only the file's mtime moves.
  let mtimeMs = 1000
  on('session.cwd', () => ({ value: '/repo' }))
  on('fs.stat', () => ({ value: { kind: 'file', size: 10, mtimeMs, isLink: false } }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    const args = e.argv.slice(e.argv.indexOf('-C') + 2)

    if (args[0] === 'rev-parse') {
      return args.includes('--show-toplevel') ? ran('/repo\n') : ran('abc\n')
    }

    return args[0] === 'status' ? ran(' M src/again.ts\0') : ran('', 1)
  })
  on('turn.start', () => ({ turnId: 't1' }))
  on('turn.complete', () => ({ text: '' }))
  await $.turn.start({ text: 'go', turnId: 't1' })
  mtimeMs = 2000
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(' 1 uncommitted edit: again.ts')
  await ui.unmount()
})

test('an already-uncommitted file nobody touched during the turn does not show', async ($, on) => {
  on('session.cwd', () => ({ value: '/repo' }))
  on('fs.stat', () => ({ value: { kind: 'file', size: 10, mtimeMs: 1000, isLink: false } }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    const args = e.argv.slice(e.argv.indexOf('-C') + 2)

    if (args[0] === 'rev-parse') {
      return args.includes('--show-toplevel') ? ran('/repo\n') : ran('abc\n')
    }

    return args[0] === 'status' ? ran(' M src/untouched.ts\0') : ran('', 1)
  })
  on('turn.start', () => ({ turnId: 't1' }))
  on('turn.complete', () => ({ text: '' }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect(await ui.find({ type: 'Text', text: /uncommitted/ })).toBeUndefined()
  await ui.unmount()
})
