// ctrl+up / ctrl+down jump between the prompts you sent, in the fullscreen
// TUI ("tui": "fullscreen"). Elsewhere the transcript is the terminal's own
// scrollback, which Claude Code cannot scroll, so the mod draws nothing and
// the keys keep their defaults.
//
// A mod hears a key only as a Button naming an engine keybinding action, and
// only while that Button is drawn; the band above the prompt holds two,
// hidden, on app:diffFileListUp/Down (ctrl+up/down and meta+up/down, or
// whatever ~/.claude/keybindings.json binds them to). While the diff panel
// is open its own handler for those actions wins, as the engine orders it.

import type { EngineInterface, Register } from 'claude-code'

import { pickTarget, positionsOf, type Direction, type OnScreen, type Seen } from './jump'

// What the render hooks last saw of each transcript row, by row id.
const seen = new Map<string, Seen>()

async function jump($: EngineInterface, direction: Direction) {
  const rows = await $.session.messages({ last: 4096 })

  if (!Array.isArray(rows)) {
    return
  }
  const target = pickTarget(direction, positionsOf(rows), seen)

  if (target !== null) {
    await $.ui.scroll({ to: { requestId: target }, block: 'start' })
  }
}

export const register: Register = on => {
  on('ui.render', ($, e, next) => {
    const props = e.props as {
      onScreen?: OnScreen | null
      origin?: { kind?: string }
      from?: unknown
    }

    if ('onScreen' in props) {
      seen.set(e.requestId, {
        // Your own prompts: not a background task's notification, nor a
        // message another agent or session sent.
        isPrompt:
          e.component === 'UserMessage' &&
          props.origin?.kind !== 'task-notification' &&
          props.from === undefined,
        onScreen: props.onScreen ?? null,
      })
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    if (e.surface !== 'terminal' || e.viewport?.isFullscreen !== true) {
      return next(e)
    }
    const { Box, Button } = $.ui.resolve(e)

    return (
      <Box display="none">
        <Button key="prev" plain label="↑" action="app:diffFileListUp" onPress={() => jump($, 'up')} />
        <Button key="next" plain label="↓" action="app:diffFileListDown" onPress={() => jump($, 'down')} />
      </Box>
    )
  })
}
