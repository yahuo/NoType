import type { EngineInterface, Register } from 'claude-code'

const TRIGGER_WINDOW_MS = 1_000
const KEY_REPEAT_INITIAL_GAP_MS = 120
const KEY_REPEAT_FAST_GAP_MS = 80
const TRANSLATION_TIMEOUT_MS = 35_000
const STATUS = 'NoType: translating…'
const BUNDLED_HELPER = '/Applications/NoType.app/Contents/Helpers/notype-editor'
// An older notype-editor takes --translate for a file to edit and starts the fallback editor;
// `false` makes it fail at once instead of opening an editor on a pipe.
const HELPER_ENVIRONMENT = {
  NOTYPE_REAL_VISUAL: 'false',
  NOTYPE_REAL_EDITOR: 'false',
  NOTYPE_EDITOR_FALLBACK: 'false',
}
// Claude Code expands these when the prompt is sent; a translation without one loses the paste.
const ATTACHMENT_PLACEHOLDER = /\[(?:Pasted text|Image|\.\.\.Truncated text) #\d+[^\]\n]*\]/g

let spaceTimestamps: number[] = []
let helperPath: string | undefined
let translationGeneration = 0
let translationInFlight = false

export const register: Register = on => {
  on('session.start', ($, e, next) => {
    // Find the helper ahead of the first trigger; the claim has 150 ms.
    void resolveHelper($)
    return next(e)
  })

  on('prompt.change', ($, e, next) => {
    spaceTimestamps = []
    return next(e)
  })

  on('prompt.edit', async ($, e, next) => {
    const end = e.text.length
    const appendsSpaces =
      e.start === end && e.end === end && e.cursor === end && /^ +$/.test(e.inputText)
    if (!appendsSpaces) {
      spaceTimestamps = []
      return next(e)
    }

    // A fast typist's taps can arrive folded into one edit, so count each Space in it.
    const now = await $.clock.now()
    let isTriggered = false
    for (let index = 0; index < e.inputText.length && !isTriggered; index += 1) {
      isTriggered = countSpace(now)
    }
    const draft = e.text + e.inputText
    const source = draft.slice(0, -3)
    if (!isTriggered || translationInFlight || !draft.endsWith('   ') || !source.trim()) {
      return next(e)
    }
    const helper = await resolveHelper($)
    if (!helper) return next(e)

    // Remove the trigger at once; if the request fails, the source stays as typed.
    void translateDraft($, helper, source)
    return { text: source, cursor: source.length }
  })
}

/** Records one Space; true when it is the third quick tap rather than a held key. */
function countSpace(now: number): boolean {
  const first = spaceTimestamps[0]
  if (first === undefined || now < first || now - first > TRIGGER_WINDOW_MS) {
    spaceTimestamps = [now]
  } else {
    spaceTimestamps.push(now)
  }
  if (spaceTimestamps.length !== 3) return false

  const [firstTap, secondTap, thirdTap] = spaceTimestamps as [number, number, number]
  spaceTimestamps = []
  // A held key has one long initial delay followed by rapid repeats.
  return !(
    secondTap - firstTap >= KEY_REPEAT_INITIAL_GAP_MS &&
    thirdTap - secondTap <= KEY_REPEAT_FAST_GAP_MS
  )
}

async function translateDraft($: EngineInterface, helper: string, source: string) {
  translationInFlight = true
  const generation = ++translationGeneration
  try {
    // NoType waits 150 ms for a direct client to claim the triple Space before it opens the
    // external editor, so the request goes out before anything else.
    const running = $.process.run([helper, '--translate'], {
      stdin: source,
      env: HELPER_ENVIRONMENT,
      timeoutMs: TRANSLATION_TIMEOUT_MS,
    })
    $.ui.status(STATUS)
    const { exitCode, stdout: translated, stderr } = await running
    if (generation !== translationGeneration) return

    if (exitCode !== 0) {
      $.ui.toast(
        stderr.trim() ||
          'NoType: notype-editor is too old for the Claude Code mod. Rerun the agent editor installer.',
      )
      return
    }
    if (!translated.trim()) {
      $.ui.toast('NoType returned an empty translation.')
      return
    }
    const dropped = source.match(ATTACHMENT_PLACEHOLDER)?.find(tag => !translated.includes(tag))
    if (dropped) {
      $.ui.toast(`NoType changed ${dropped}, so the draft was not overwritten.`)
      return
    }

    const box = await $.prompt.read()
    const appendedSpaces = box.text.slice(source.length)
    // Extra Space taps while waiting must not discard a completed translation.
    // Keep that spacing, but never overwrite an edited or submitted draft.
    if (!box.text.startsWith(source) || /[^ ]/.test(appendedSpaces)) {
      $.ui.toast('NoType finished, but the draft changed, so it was not overwritten.')
      return
    }
    const filled = await $.prompt.fill({ text: translated + appendedSpaces, mode: 'replace' })
    if (!filled.isFilled) {
      $.ui.toast('NoType finished, but the prompt box is busy, so the draft was not overwritten.')
    }
  } catch (error) {
    if (generation === translationGeneration) {
      $.ui.toast(`NoType: ${error instanceof Error ? error.message : String(error)}`)
    }
  } finally {
    if (generation === translationGeneration) {
      translationInFlight = false
      $.ui.status(undefined)
    }
  }
}

async function resolveHelper($: EngineInterface): Promise<string | undefined> {
  helperPath ??= await findHelper($)
  return helperPath
}

/** The installed `notype-editor`: an explicit override, the agent editor install, or the app's. */
async function findHelper($: EngineInterface): Promise<string | undefined> {
  const override = await $.env.get('NOTYPE_EDITOR_HELPER')
  const home = await $.env.get('HOME')
  const candidates = override
    ? [override]
    : [...(home ? [`${home}/.local/bin/notype-editor`] : []), BUNDLED_HELPER]
  for (const candidate of candidates) {
    if (await $.fs.exists(candidate)) return candidate
  }
  return undefined
}
