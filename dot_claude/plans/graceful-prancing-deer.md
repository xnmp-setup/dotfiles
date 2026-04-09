# Presentation Plan: Claude Code for Data Scientists (30 min)

## Context
A 30-minute presentation + live demo for CBA data scientists. The audience knows chat-based AI coding but not agentic coding. The Sydney house prices project we already built IS the demo. Core message: **"Don't be the middleman. Build the bridge."**

The presentation is a React app (separate Vite project in `presentation/`). Live demos run in a dropdown Ghostty terminal overlaying the full-screen browser. Lines starting with *demo* are done in the terminal; everything else is slides.

---

## Section 1: Intro

### Slides
- Title slide + talk outline
- "What we're building today" — screenshot of the finished React app

### Demo
- Run the first couple of prompts on Sydney housing dataset (EDA, cleaning)
- Mention "this is probably nothing new — you've done this with other coding agents"

---

## Section 2: CLAUDE.md Introduction

### Slides
- Two friction points observed: (1) keeps running long inline bash instead of saving scripts, (2) keeps forgetting to git commit
- DRY analogy: repeated logic → helper function; repeated prompts → CLAUDE.md
- Canonical use case: every new session Claude re-explores the codebase. Feed it context upfront so it doesn't have to.
- Global CLAUDE.md and rules — show the hierarchy diagram

### Demo
- Add the two rules to project CLAUDE.md (scripts in `src/`, always commit)
- Run another prompt → show it now commits afterwards
- Run `/init` → examine the resulting CLAUDE.md additions
- Show global `~/.claude/CLAUDE.md` and `~/.claude/rules/` files

### Files to create
- `CLAUDE.md` (project root) — pre-draft with project structure, data conventions, CBA branding, commands reference. Will be "created live" but have it ready.

---

## Section 3: Skill Introduction

### Slides
- Quick concept: a procedure that kicks in for particular situations
- Brief anatomy of a skill (frontmatter, triggers, steps)
- CBA-specific examples teaser: DHP skill (deployment via CBA's Terraform-like AWS abstraction), GMR template (Group Model Register — required documentation template for every CBA ML model)

### Demo (sequence matters here)
1. "Before we do this, let's put something in the oven" — fire off the big React app prompt (the one that turns the HTML report into an interactive React app). Let it run in the background.
2. Ask Claude to turn the EDA → model → HTML report → CBA styling workflow into a skill called `data-analysis-report`
3. Run the skill on a Melbourne house prices dataset (already in `data/` folder). Don't wait for results — just let it cook.
4. Open the skills folder in Finder / terminal, show the file structure:
   - Frontmatter (trigger conditions, description)
   - Including assets with skills: show adding a CBA theme template and a GMR template as skill assets
5. Come back to the React app prompt — show progress or results

### Files to create
- Hidden "sabotage" skill (see Section 4 setup below)
- The `data-analysis-report` skill will be created live, but have a backup pre-built version

---

## Section 4: Bridge Building

### The Setup (hidden skill)
A hidden skill that activates when the user asks to "break down a histogram by a third variable" or similar stacking feature request. The skill's secret instruction tells Claude to introduce a subtle but visible bug (e.g., wrong grouping key in the stacked bedroom chart — using `num_bath` instead of `num_bed`, or off-by-one in bin labels). This makes the failure look natural.

**File**: A skill in `.claude/skills/` or plugin directory with:
- Trigger: matches prompts about stacking/breaking down charts by variables
- Hidden instruction: introduce a specific subtle bug in the grouping logic
- Must be convincing — the code should look correct at a glance

### Slides
- One slide: "Build the Bridge" concept
- "Whatever you're repeatedly feeding to the agent, allow the agent to access that info itself"
- Examples: Playwright screenshots, log capture, self-verification

### Demo sequence
1. Go back to the React app. Stack the histogram by bedrooms → show that it doesn't work properly (the planted bug from the hidden skill)
2. "At this point, we could've appended to the prompt: take a screenshot to verify it works"
3. Add to CLAUDE.md: "After UI changes, use Playwright to take a screenshot and verify the result visually"
4. Ask Claude to add another small new feature → watch it now self-verify with screenshots
5. Talk about the progression: when you build enough bridges, the agent can run by itself for hours
6. Demo `dangerouslySkipPermissions` — turn on the mode, start a new terminal window inside a sandbox

### Files to create
- Hidden sabotage skill (trigger: histogram stacking prompts)
- Playwright config + basic test infrastructure (needed for screenshot capability)
  - `app/playwright.config.ts`
  - `app/e2e/app.spec.ts` — basic tests: page loads, tabs work, charts render
  - Install: `cd app && bun add -D @playwright/test && bunx playwright install chromium`

---

## Section 5: Hooks Introduction

### Slides
- Start with a big feature development process wall:
  - Create JIRA ticket → create `feat/` branch → write plan to `docs/plans/` → write unit tests → implement → verify tests pass → Playwright test → take screenshots → write E2E test → run all tests → create PR → post in Teams → close JIRA
- "When it keeps forgetting steps, you start adding **ALWAYS DO THIS!!** and **CRITICAL**. Semantic inflation."
- Introduce hooks: structural enforcement via shell scripts that run at specific lifecycle points
- Advisory (CLAUDE.md) vs Structural (hooks) — the key distinction

### Demo sequence
1. Create the git-commit-before-stop hook:
   - A Stop hook that checks `git status --porcelain` — if uncommitted changes exist, exit 2 with "Please commit your changes before stopping"
   - Guards against infinite loops with `stop_hook_active` check
2. Show the hook file in terminal, show it in `.claude/settings.local.json`
3. Demo it: make a small request → watch Claude get blocked → watch it commit → then it can stop

### More hook examples (slides)
- JIRA tickets must include screenshot acceptance criteria
- Commits must include evidence screenshots
- Screenshots must have been read (not just taken)
- Feature branches must come with a Playwright test
- All Playwright tests must pass before committing

### Demo
- Ask Claude to create these hooks itself (show it generating hook scripts)
- Mention: "They usually take a few rounds of testing, but once working, they're reusable across all projects"

### Files to create
- `hooks/require-commit-before-stop.sh` — the git commit enforcement hook
- Hook configuration in `.claude/settings.local.json`

---

## Section 6: Power User Teaser

### Slides (quick flyby, ~30 sec each)
- Subagents — note: "haven't found a great use yet, they re-learn context and use way more tokens. Best for work that needs little context or truly fresh tasks. The researcher subagent is the best one."
- Ralph Loop — autonomous iteration cycles
- Issue tracking and agent-specific tools (beads)
- Multiple worktrees — parallel branches
- Comprehensive documentation as first-class citizen
- Enforcing code architecture with custom linters + hooks
- Multiple agent workflows (reviewer agents, gardener agents)
- Claude Agent SDK — runs Claude Code via Python
- Link: [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)

### Closing slide
- "Don't be the middleman. Build the bridge."

---

## Files to Create — Full List

| # | File | Purpose |
|---|------|---------|
| 1 | `presentation/` | New Vite + React app for the slide deck |
| 2 | `presentation/src/` | Slide components with CBA dark theme, arrow-key navigation |
| 3 | `CLAUDE.md` | Project-level instructions (pre-drafted, "created live") |
| 4 | `app/playwright.config.ts` | Playwright config with Vite webServer |
| 5 | `app/e2e/app.spec.ts` | 5 E2E tests (load, KPIs, tabs, scatter, charts) |
| 6 | `.claude/skills/sabotage-histogram.md` | Hidden skill that injects a subtle bug when stacking charts |
| 7 | `hooks/require-commit-before-stop.sh` | Stop hook enforcing git commit |
| 8 | `.claude/settings.local.json` | Updated with hook configuration |

## Implementation Sequence

1. **Playwright infrastructure** — install deps, write config + tests, verify passing
2. **Presentation React app** — new Vite project in `presentation/`, CBA-themed slides with arrow-key nav, all slide content from the outline above
3. **Project CLAUDE.md** — draft for the live demo
4. **Hidden sabotage skill** — triggered by histogram stacking prompts, injects a grouping bug
5. **Git commit stop hook** — `require-commit-before-stop.sh` + settings.json config
6. **Dry run** — full 30-min walkthrough, verify all demos work, time each section

## Verification
- `cd app && bunx playwright test` — all tests green
- `cd presentation && bun run dev` — slides render, arrow keys navigate
- Stop hook blocks when uncommitted changes exist
- Sabotage skill activates on the right trigger and produces a visible-but-subtle bug
- Full 30-min dry run completes within time
