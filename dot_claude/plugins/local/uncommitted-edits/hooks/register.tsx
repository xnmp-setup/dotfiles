// uncommitted-edits: a dim line above the prompt naming the files Claude edited this
// session that git still shows as uncommitted, or, when a commit since the last
// turn's first edit took its edits, a green-ticked `✓ N edits committed` line
// until the next turn ends (an edit undone again is clean, not committed). Needs `git` on PATH; without it,
// or outside a repo, nothing is drawn.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import { addPath, bandFor, isSuccess, markOf, summary, without } from './commit'
import { checkTracked, committedSince, headOf } from './repo'

const SHAPE = { shape: 'v1' }
const edited = atom({ plugin: 'uncommitted-edits', key: 'edited' } as const, [], SHAPE)
const dirty = atom({ plugin: 'uncommitted-edits', key: 'dirty' } as const, [], SHAPE)
// Files edited in the main turn still running, and in the last one that ended.
const thisTurn = atom({ plugin: 'uncommitted-edits', key: 'thisTurn' } as const, [], SHAPE)
const lastTurn = atom({ plugin: 'uncommitted-edits', key: 'lastTurn' } as const, [], SHAPE)
// HEAD when the running / last main turn first edited (null: none yet, or no commit).
const thisBase = atom({ plugin: 'uncommitted-edits', key: 'thisBase' } as const, null, SHAPE)
const lastBase = atom({ plugin: 'uncommitted-edits', key: 'lastBase' } as const, null, SHAPE)
// Of lastTurn, the files now clean that a commit since lastBase touched.
const committed = atom({ plugin: 'uncommitted-edits', key: 'committed' } as const, [], SHAPE)

const DEFAULT_COLUMNS = 80
const POLL_MS = 60_000

// Module-level on purpose: a reload re-runs register and starts both afresh.
let isChecking = false
let timer: Timer | undefined

async function track($: EngineInterface, path: unknown) {
  try {
    if ((await read($, thisTurn)).length === 0) {
      // The turn's first edit: what HEAD was before any of its commits.
      const head = await headOf($, await $.session.cwd())
      await update($, thisBase, () => head)
    }
    await update($, edited, paths => addPath(paths, path))
    await update($, thisTurn, paths => addPath(paths, path))
  } catch {
    // Tracking must never break the tool call.
  }
}

async function refresh($: EngineInterface) {
  if (isChecking) {
    return
  }
  isChecking = true

  try {
    const last = await read($, lastTurn)
    const tracked = [...new Set([...(await read($, edited)), ...last])]
    const check = tracked.length === 0 ? null : await checkTracked($, await $.session.cwd(), tracked)

    if (check === null) {
      // Nothing checkable (no git, no repo, nothing tracked): show nothing.
      await update($, dirty, () => [])
      await update($, committed, () => [])
    } else {
      await update($, dirty, () => check.dirty)
      // Clean is not committed: an edit undone again is clean too.
      const clean = last.filter(f => check.clean.includes(f))
      const cwd = await $.session.cwd()
      const touched = await committedSince($, cwd, await read($, lastBase), clean)
      await update($, committed, () => touched)
      // Only what was checked clean leaves; an edit made meanwhile stays.
      await update($, edited, paths => without(paths, check.clean))
    }
  } catch {
    // Degrade silently.
  } finally {
    isChecking = false
  }
}

async function endTurn($: EngineInterface) {
  try {
    const edits = await read($, thisTurn)
    const base = await read($, thisBase)
    await update($, lastTurn, () => edits)
    await update($, lastBase, () => base)
    await update($, thisTurn, () => [])
    await update($, thisBase, () => null)
  } catch {
    // Degrade silently.
  }
  await refresh($)
}

export const register: Register = on => {
  on('tool.call', { tool: 'Edit' }, async ($, e, next) => {
    const ran = await next(e)

    if (isSuccess(ran)) {
      await track($, e.file_path)
    }

    return ran
  })

  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    const ran = await next(e)

    if (isSuccess(ran)) {
      await track($, e.file_path)
    }

    return ran
  })

  on('tool.call', { tool: 'NotebookEdit' }, async ($, e, next) => {
    const ran = await next(e)

    if (isSuccess(ran)) {
      await track($, e.notebook_path)
    }

    return ran
  })

  on('session.start', async ($, e, next) => {
    timer?.cancel()
    timer = $.clock.every(POLL_MS, () => void refresh($))
    void refresh($)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    // A subagent's turn ending is not the main turn ending.
    // Git runs after the turn has ended, never holding it up (slow repos).
    if (e.agentId === undefined) {
      void endTurn($)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const band = bandFor(await read($, dirty), await read($, lastTurn), await read($, committed))

    if (band === null || e.props.hasSurvey) {
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)
    const width = e.props.bodyColumns > 0 ? e.props.bodyColumns : DEFAULT_COLUMNS

    const line = summary(band.files, width, band.kind)
    const mark = markOf(band.kind)

    return (
      <Box>
        <Text color={band.kind === 'committed' ? 'success' : undefined} dimColor={band.kind !== 'committed'}>
          {mark}
        </Text>
        <Text dimColor>{line.slice(mark.length)}</Text>
      </Box>
    )
  })
}
