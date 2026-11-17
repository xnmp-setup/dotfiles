// Which prompt a jump lands on: pure, so it is tested without a terminal.
//
// The engine reports, for every transcript row it draws, which of the row's
// lines the fullscreen viewport shows (`onScreen`, null when none). Rows are
// keyed by id but arrive in no reliable order, so their order comes from the
// session's messages: a message row is keyed by its uuid, a tool row by its
// tool_use_id (placed with the assistant message that made the call), and a
// collapsed tool group by `collapsed-<uuid>`.

export type OnScreen = { readonly first: number; readonly last: number; readonly of: number }

/** What the render hooks last saw of one row. */
export type Seen = { readonly isPrompt: boolean; readonly onScreen: OnScreen | null }

/** The parts of a `$.session.messages()` row the ordering reads. */
export type MessageRow = {
  readonly uuid?: string
  readonly toolUses: readonly { readonly tool_use_id: string }[]
}

export type Direction = 'up' | 'down'

/** Each row id's place in the transcript, oldest first. */
export function positionsOf(rows: readonly MessageRow[]): ReadonlyMap<string, number> {
  return new Map(
    rows.flatMap((row, index): [string, number][] => [
      ...(row.uuid === undefined ? [] : [[row.uuid, index] as [string, number]]),
      ...row.toolUses.map((use): [string, number] => [use.tool_use_id, index]),
    ]),
  )
}

function positionOf(id: string, positions: ReadonlyMap<string, number>): number | undefined {
  return positions.get(id) ?? positions.get(id.replace(/^collapsed-/, ''))
}

/**
 * The prompt to bring to the top of the viewport, or null for none.
 *
 * `up`: the nearest prompt whose first line is above the viewport's top,
 * which is the topmost visible prompt itself when its first lines are
 * scrolled away. `down`: the nearest prompt below the topmost visible row.
 * Rows the session does not list (a cleared conversation's) are ignored.
 */
export function pickTarget(
  direction: Direction,
  positions: ReadonlyMap<string, number>,
  seen: ReadonlyMap<string, Seen>,
): string | null {
  const placed = [...seen].flatMap(([id, row]) => {
    const position = positionOf(id, positions)

    return position === undefined ? [] : [{ id, position, ...row }]
  })
  const visible = placed.filter(row => row.onScreen !== null)

  if (visible.length === 0) {
    return null
  }
  const top = Math.min(...visible.map(row => row.position))
  const prompts = placed.filter(row => row.isPrompt).sort((a, b) => a.position - b.position)

  if (direction === 'down') {
    return prompts.find(row => row.position > top)?.id ?? null
  }
  const cut = prompts.find(row => row.position === top && (row.onScreen?.first ?? 0) > 0)

  return cut?.id ?? prompts.filter(row => row.position < top).at(-1)?.id ?? null
}
