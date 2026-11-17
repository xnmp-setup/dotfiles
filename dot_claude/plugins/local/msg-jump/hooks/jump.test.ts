import { expect, test } from 'claude-code/testing'

import { pickTarget, positionsOf, type OnScreen, type Seen } from './jump'

// A transcript, oldest first: prompt, reply with a tool call, reply,
// prompt, reply, task notification, prompt, reply.
const ROWS = [
  { uuid: 'p1', toolUses: [] },
  { uuid: 'a1', toolUses: [{ tool_use_id: 'toolu_1' }] },
  { uuid: 'r1', toolUses: [] },
  { uuid: 'a1b', toolUses: [] },
  { uuid: 'p2', toolUses: [] },
  { uuid: 'a2', toolUses: [] },
  { uuid: 'n1', toolUses: [] },
  { uuid: 'p3', toolUses: [] },
  { uuid: 'a3', toolUses: [] },
]
const POSITIONS = positionsOf(ROWS)
const OFF = null
const whole = (of: number): OnScreen => ({ first: 0, last: of - 1, of })
const tail = (first: number, of: number): OnScreen => ({ first, last: of - 1, of })

const prompt = (onScreen: OnScreen | null): Seen => ({ isPrompt: true, onScreen })
const other = (onScreen: OnScreen | null): Seen => ({ isPrompt: false, onScreen })

/** Rows as the render hooks saw them, in the arbitrary order they drew. */
function seen(entries: Record<string, Seen>): ReadonlyMap<string, Seen> {
  return new Map(Object.entries(entries).reverse())
}

test('up from inside a reply goes to the prompt that started it', () => {
  const rows = seen({ p1: prompt(OFF), p2: prompt(OFF), a2: other(tail(5, 40)), p3: prompt(OFF) })
  expect(pickTarget('up', POSITIONS, rows)).toBe('p2')
})

test('up from a prompt already at the top goes to the one before', () => {
  const rows = seen({ p1: prompt(OFF), p2: prompt(whole(2)), a2: other(whole(4)), p3: prompt(whole(1)) })
  expect(pickTarget('up', POSITIONS, rows)).toBe('p1')
})

test('up first reveals a prompt whose opening lines are scrolled away', () => {
  const rows = seen({ p1: prompt(OFF), p2: prompt(tail(3, 6)), a2: other(whole(4)) })
  expect(pickTarget('up', POSITIONS, rows)).toBe('p2')
})

test('down goes to the next prompt below the top row, even one already visible', () => {
  const rows = seen({ p1: prompt(OFF), a1: other(tail(2, 9)), p2: prompt(whole(2)), p3: prompt(OFF) })
  expect(pickTarget('down', POSITIONS, rows)).toBe('p2')
})

test('down from a prompt at the top goes to the following prompt', () => {
  const rows = seen({ p2: prompt(whole(2)), a2: other(whole(4)), n1: other(OFF), p3: prompt(OFF) })
  expect(pickTarget('down', POSITIONS, rows)).toBe('p3')
})

test('task notifications and other non-prompt rows are never targets', () => {
  const rows = seen({ p2: prompt(OFF), n1: other(OFF), p3: prompt(OFF), a3: other(tail(1, 3)) })
  expect(pickTarget('up', POSITIONS, rows)).toBe('p3')
  expect(pickTarget('down', POSITIONS, seen({ a2: other(whole(3)), n1: other(OFF) }))).toBe(null)
})

test('tool rows and collapsed groups take their assistant message position', () => {
  expect(pickTarget('up', POSITIONS, seen({ p1: prompt(OFF), toolu_1: other(tail(4, 20)), p2: prompt(OFF) }))).toBe('p1')
  expect(pickTarget('down', POSITIONS, seen({ 'collapsed-a1': other(whole(2)), p2: prompt(OFF) }))).toBe('p2')
})

test('nothing to jump to at either end of the transcript', () => {
  const atTop = seen({ p1: prompt(whole(2)), a1: other(whole(3)), p2: prompt(OFF) })
  expect(pickTarget('up', POSITIONS, atTop)).toBe(null)
  const atBottom = seen({ p3: prompt(tail(1, 2)), a3: other(whole(9)) })
  expect(pickTarget('down', POSITIONS, atBottom)).toBe(null)
})

test('no visible row, unknown rows, or an empty session: no jump', () => {
  expect(pickTarget('up', POSITIONS, seen({ p1: prompt(OFF), p2: prompt(OFF) }))).toBe(null)
  expect(pickTarget('up', POSITIONS, new Map())).toBe(null)
  // Rows of a cleared conversation stay in the map but the session lists none.
  const stale = seen({ old: prompt(whole(2)), gone: other(whole(5)) })
  expect(pickTarget('up', POSITIONS, stale)).toBe(null)
  expect(pickTarget('down', positionsOf([]), seen({ p1: prompt(whole(1)) }))).toBe(null)
})

test('rows without a uuid are skipped when ordering', () => {
  const positions = positionsOf([{ toolUses: [] }, { uuid: 'p', toolUses: [] }, { uuid: 'a', toolUses: [] }])
  expect(pickTarget('up', positions, seen({ p: prompt(OFF), a: other(tail(2, 4)) }))).toBe('p')
})
