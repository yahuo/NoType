import type {
  On,
  ProcessRunInit,
  ProcessRunResult,
  PromptBox,
  PromptEditInput,
  PromptEditResult,
} from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

const HELPER = '/home/me/.local/bin/notype-editor'

type Run = { argv: readonly string[]; init?: ProcessRunInit }

/** The engine beneath the mod: the prompt box, the helper and what the mod showed. */
function world(
  on: On,
  answer: (run: Run) => ProcessRunResult | Promise<ProcessRunResult>,
  installed = true,
) {
  const state = {
    box: { text: '', cursor: 0 } as PromptBox,
    runs: [] as Run[],
    toasts: [] as string[],
    statuses: [] as (string | undefined)[],
  }
  const clock = mock.clock(on, { now: 10_000 })
  mock.env(on, { HOME: '/home/me' })
  on('fs.exists', ($, e) => ({ value: installed && e.path === HELPER }))
  on('process.run', async ($, e) => {
    state.runs.push({ argv: e.argv, init: e.init })
    return { value: await answer({ argv: e.argv, init: e.init }) }
  })
  on('prompt.edit', ($, e) => ({
    text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end),
    cursor: e.start + e.inputText.length,
  }))
  on('prompt.read', () => ({ value: state.box }))
  on('prompt.fill', ($, e) => {
    state.box = { text: e.text, cursor: e.text.length }
    return { isFilled: true }
  })
  on('ui.status', ($, e) => {
    state.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    state.toasts.push(e.text)
    return { value: undefined }
  })
  return { state, clock }
}

/** Raises `prompt.edit` as the composer does; the kit's typed `$` leaves out engine-only events. */
const edit = ($: Engine, e: Omit<PromptEditInput, 'origin'>) =>
  ($ as unknown as { prompt: { edit: (e: PromptEditInput) => Promise<PromptEditResult> } }).prompt.edit({
    origin: { kind: 'composer' },
    ...e,
  })

const ran = (stdout: string, exitCode = 0, stderr = ''): ProcessRunResult => ({
  exitCode,
  stdout,
  stderr,
  isStdoutTruncated: false,
  isStderrTruncated: false,
})

/** Types `input` at the end of the box, one key per character `gapMs` apart. */
async function type($: Engine, clock: MockClock, state: { box: PromptBox }, input: string, gapMs = 50) {
  for (const character of input) {
    const { text, cursor } = state.box
    state.box = await edit($, {
      key: { key: character },
      text,
      cursor,
      start: cursor,
      end: cursor,
      inputText: character,
    })
    await clock.advance(gapMs)
  }
}

test('three quick Spaces translate the draft in place', async ($, on) => {
  const { state, clock } = world(on, () => ran('Please continue.'))
  state.box = { text: '请继续', cursor: 3 }

  await type($, clock, state, '   ')
  await clock.settle()

  expect(state.runs).toHaveLength(1)
  expect(state.runs[0]?.argv).toEqual([HELPER, '--translate'])
  expect(state.runs[0]?.init?.stdin).toBe('请继续')
  expect(state.runs[0]?.init?.env?.NOTYPE_EDITOR_FALLBACK).toBe('false')
  expect(state.box).toEqual({ text: 'Please continue.', cursor: 16 })
  expect(state.statuses).toEqual(['NoType: translating…', undefined])
  expect(state.toasts).toEqual([])
})

test('the trigger leaves the draft without its Spaces while NoType translates', async ($, on) => {
  let finish: (result: ProcessRunResult) => void = () => {}
  const { state, clock } = world(on, () => new Promise(resolve => (finish = resolve)))
  state.box = { text: '请继续', cursor: 3 }

  await type($, clock, state, '   ')
  expect(state.box).toEqual({ text: '请继续', cursor: 3 })

  // Spaces typed while waiting are kept after the translation.
  await type($, clock, state, ' ', 2_000)
  finish(ran('Please continue.'))
  await clock.settle()
  expect(state.box.text).toBe('Please continue. ')
})

test('spaces folded into one edit still count as taps', async ($, on) => {
  const { state, clock } = world(on, () => ran('Please continue.'))
  state.box = await edit($, {
    text: '请继续',
    cursor: 3,
    start: 3,
    end: 3,
    inputText: '   ',
  })
  await clock.settle()

  expect(state.runs).toHaveLength(1)
  expect(state.box.text).toBe('Please continue.')
})

test('a held Space or slow taps do not trigger', async ($, on) => {
  const { state, clock } = world(on, () => ran('unexpected'))
  state.box = { text: 'draft', cursor: 5 }

  // Key repeat: a long initial delay, then rapid repeats.
  const { text, cursor } = state.box
  state.box = await edit($, {
    key: { key: ' ' },
    text,
    cursor,
    start: cursor,
    end: cursor,
    inputText: ' ',
  })
  await clock.advance(400)
  await type($, clock, state, '  ', 30)
  await type($, clock, state, 'x')
  await type($, clock, state, '   ', 600)
  await clock.settle()

  expect(state.runs).toEqual([])
  expect(state.box.text).toBe('draft   x   ')
})

test('another key between the Spaces resets the trigger', async ($, on) => {
  const { state, clock } = world(on, () => ran('unexpected'))
  state.box = { text: 'draft', cursor: 5 }

  await type($, clock, state, '  a ')
  await clock.settle()

  expect(state.runs).toEqual([])
  expect(state.box.text).toBe('draft  a ')
})

test('a blank draft or a caret before the end is left alone', async ($, on) => {
  const { state, clock } = world(on, () => ran('unexpected'))
  await type($, clock, state, '   ')
  expect(state.box.text).toBe('   ')

  state.box = { text: 'draft', cursor: 2 }
  for (let tap = 0; tap < 3; tap += 1) {
    const { text, cursor } = state.box
    state.box = await edit($, {
      key: { key: ' ' },
      text,
      cursor,
      start: cursor,
      end: cursor,
      inputText: ' ',
    })
  }
  await clock.settle()

  expect(state.runs).toEqual([])
  expect(state.box.text).toBe('dr   aft')
})

test('an edited draft is not overwritten', async ($, on) => {
  let finish: (result: ProcessRunResult) => void = () => {}
  const { state, clock } = world(on, () => new Promise(resolve => (finish = resolve)))
  state.box = { text: '请继续', cursor: 3 }

  await type($, clock, state, '   ')
  await type($, clock, state, '吧')
  finish(ran('Please continue.'))
  await clock.settle()

  expect(state.box.text).toBe('请继续吧')
  expect(state.toasts).toEqual(['NoType finished, but the draft changed, so it was not overwritten.'])
})

test('a translation that drops a paste placeholder is not applied', async ($, on) => {
  const { state, clock } = world(on, () => ran('Look at this log.'))
  const source = '看看这个日志 [Pasted text #1 +12 lines]'
  state.box = { text: source, cursor: source.length }

  await type($, clock, state, '   ')
  await clock.settle()

  expect(state.runs).toHaveLength(1)
  expect(state.box.text).toBe(source)
  expect(state.toasts).toEqual([
    'NoType changed [Pasted text #1 +12 lines], so the draft was not overwritten.',
  ])
})

test('helper failures are shown and keep the source', async ($, on) => {
  const { state, clock } = world(on, run =>
    run.init?.stdin === '旧版' ? ran('', 1) : ran('', 1, 'NoType: Unable to connect to NoType\n'),
  )
  state.box = { text: '请继续', cursor: 3 }
  await type($, clock, state, '   ')
  await clock.settle()
  expect(state.box.text).toBe('请继续')

  state.box = { text: '旧版', cursor: 2 }
  await type($, clock, state, '   ')
  await clock.settle()

  expect(state.toasts).toEqual([
    'NoType: Unable to connect to NoType',
    'NoType: notype-editor is too old for the Claude Code mod. Rerun the agent editor installer.',
  ])
})

test('without an installed helper the Spaces are typed as usual', async ($, on) => {
  const { state, clock } = world(on, () => ran('unexpected'), false)
  state.box = { text: '请继续', cursor: 3 }

  await type($, clock, state, '   ')
  await clock.settle()

  expect(state.runs).toEqual([])
  expect(state.box.text).toBe('请继续   ')
})
