declare module 'claude-code' {
  interface PluginState {
    'uncommitted-edits': {
      // Absolute paths Claude edited successfully and that were not yet seen clean.
      edited: Shaped<string[]>
      // The subset of those that git last reported as uncommitted.
      dirty: Shaped<string[]>
      // Files edited in the main turn still running / the last one that ended.
      thisTurn: Shaped<string[]>
      lastTurn: Shaped<string[]>
      // HEAD at the running / last turn's first edit.
      thisBase: Shaped<string | null>
      lastBase: Shaped<string | null>
      // Of lastTurn, the files now clean that a commit since lastBase touched.
      committed: Shaped<string[]>
    }
  }
}
