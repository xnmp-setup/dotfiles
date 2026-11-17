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

// A fake git for a repo at /repo; `dirty` is what `status` reports.
const fakeGit = (dirty: string) => (argv: readonly string[]) => {
  const args = argv.slice(argv.indexOf('-C') + 2)
  const out = (stdout: string, exitCode = 0) => ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })

  switch (args[0]) {
    case 'rev-parse':
      return out('/repo\n')
    case 'status':
      return out(dirty)
    default:
      return out('', 1)
  }
}

async function editAndFinishTurn($: any, on: any, dirty: string) {
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => fakeGit(dirty)(e.argv))
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

  expect((await ui.find({ type: 'Text', text: /uncommitted/ }))?.text).toBe(
    '● 1 uncommitted edit: register.tsx',
  )
  await ui.unmount()
})

test('when the last turn\'s edits are all committed, the band says so', async ($, on) => {
  await editAndFinishTurn($, on, '')
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect((await ui.find({ type: 'Text', text: /committed/ }))?.text).toBe('✓ 1 edit committed: register.tsx')
  expect(await ui.find({ type: 'Text', text: /uncommitted/ })).toBeUndefined()
  await ui.unmount()
})

test('a later turn with no edits clears the committed mark', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await editAndFinishTurn($, on, '')
  await settle($)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't2', reason: 'answer' })
  await settle($)

  const ui = await $.ui.mount(BAND as never)

  expect(await ui.find({ type: 'Text', text: /committed/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /engine/ })).toBeDefined()
  await ui.unmount()
})
