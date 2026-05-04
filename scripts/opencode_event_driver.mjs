#!/usr/bin/env node
import { Buffer } from 'node:buffer'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const args = Object.fromEntries(
  process.argv.slice(2).map((arg) => {
    const index = arg.indexOf('=')
    if (index === -1) return [arg.replace(/^--/, ''), '']
    return [arg.slice(0, index).replace(/^--/, ''), arg.slice(index + 1)]
  }),
)

const repo = fs.realpathSync(path.resolve(args.repo || ''))
const pluginPath = path.resolve(args.plugin || '')
const rpcPath = path.resolve(args.rpc || path.join(process.cwd(), 'rpc', 'nvim-rpc.sh'))

if (!repo || !fs.existsSync(repo)) throw new Error('--repo must point at the temp git repo')
if (!pluginPath || !fs.existsSync(pluginPath)) throw new Error('--plugin must point at generated nvim-claude.js')
if (!fs.existsSync(rpcPath)) throw new Error('--rpc must point at rpc/nvim-rpc.sh')

const artifacts = path.join(repo, '.nvim-claude-opencode-debug')
fs.mkdirSync(artifacts, { recursive: true })

const runtimePlugin = path.join(artifacts, 'nvim-claude-plugin-under-test.mjs')
fs.copyFileSync(pluginPath, runtimePlugin)

const { NvimClaude } = await import(pathToFileURL(runtimePlugin))
const plugin = await NvimClaude({ directory: repo, worktree: repo, $: {} })

const events = []

const run = (cmd, commandArgs, options = {}) => {
  const result = spawnSync(cmd, commandArgs, {
    cwd: options.cwd || repo,
    env: { ...process.env, TARGET_FILE: repo, ...(options.env || {}) },
    encoding: 'utf8',
  })
  if (result.status !== 0) {
    throw new Error([
      `Command failed: ${cmd} ${commandArgs.join(' ')}`,
      `status=${result.status}`,
      result.stdout,
      result.stderr,
    ].filter(Boolean).join('\n'))
  }
  return result.stdout.trim()
}

const writeFile = (relativePath, content) => {
  const full = path.join(repo, relativePath)
  fs.mkdirSync(path.dirname(full), { recursive: true })
  fs.writeFileSync(full, content)
  return full
}

const callHook = async (name, input, output) => {
  events.push({ name, input, output })
  const hook = plugin[name]
  if (typeof hook !== 'function') throw new Error(`Generated plugin has no ${name} hook`)
  await hook(input, output)
}

const queryNvim = (files) => {
  const payload = Buffer.from(JSON.stringify({ root: repo, files }), 'utf8').toString('base64')
  const expr = `luaeval("(function(payload) local data = vim.json.decode(vim.base64.decode(payload)); vim.fn.chdir(data.root); local events = require('nvim-claude.events'); local inline = require('nvim-claude.inline_diff'); local out = { baseline = inline.get_baseline_ref(data.root), edited = events.list_edited_files(data.root), turn = events.get_turn_files(data.root), diffs = {} }; for _, file in ipairs(data.files or {}) do vim.cmd('edit ' .. vim.fn.fnameescape(file)); local bufnr = vim.api.nvim_get_current_buf(); pcall(vim.cmd, 'checktime'); pcall(inline.refresh_inline_diff, bufnr); local state = inline.get_diff_state(bufnr); table.insert(out.diffs, { file = file, hunk_count = state and #state.hunks or 0 }); end; return out end)('${payload}')")`
  const output = run(rpcPath, ['--remote-expr', expr])
  return JSON.parse(output)
}

const dumpDebug = (error, state) => {
  fs.writeFileSync(path.join(artifacts, 'events.json'), JSON.stringify(events, null, 2))
  fs.writeFileSync(path.join(artifacts, 'state.json'), JSON.stringify(state || null, null, 2))
  fs.writeFileSync(path.join(artifacts, 'error.txt'), `${error.stack || error.message || error}\n`)
  try {
    fs.writeFileSync(path.join(artifacts, 'git-status.txt'), run('git', ['status', '--short']))
  } catch {}
  console.error(`OpenCode integration debug artifacts: ${artifacts}`)
}

const assertIncludes = (values, expected, label) => {
  if (!values.includes(expected)) {
    throw new Error(`${label} missing ${expected}; got ${JSON.stringify(values)}`)
  }
}

const assertHunks = (state, files) => {
  for (const file of files) {
    const entry = state.diffs.find((item) => item.file === path.join(repo, file))
    if (!entry) throw new Error(`No diff state returned for ${file}`)
    if (entry.hunk_count < 1) throw new Error(`Expected at least one hunk for ${file}; got ${entry.hunk_count}`)
  }
}

let state = null
try {
  await callHook(
    'tool.execute.before',
    { callID: 'edit-alpha', tool: 'edit' },
    { args: { filePath: path.join(repo, 'alpha.txt'), oldString: 'alpha old', newString: 'alpha new' } },
  )
  writeFile('alpha.txt', 'alpha new\n')
  await callHook(
    'tool.execute.after',
    { callID: 'edit-alpha', tool: 'edit' },
    { metadata: { filediff: { file: path.join(repo, 'alpha.txt'), additions: 1, deletions: 1 } } },
  )

  await callHook(
    'tool.execute.before',
    { callID: 'patch-beta', tool: 'apply_patch' },
    { args: { patchText: '*** Begin Patch\n*** Update File: beta.txt\n@@\n-beta old\n+beta new\n*** End Patch' } },
  )
  writeFile('beta.txt', 'beta new\n')
  await callHook(
    'tool.execute.after',
    { callID: 'patch-beta', tool: 'apply_patch' },
    { metadata: { files: [{ filePath: path.join(repo, 'beta.txt'), relativePath: 'beta.txt', type: 'update' }] } },
  )

  await callHook(
    'tool.execute.before',
    { callID: 'patch-new', tool: 'apply_patch' },
    { args: { patchText: '*** Begin Patch\n*** Add File: nested/new.txt\n+new file\n*** End Patch' } },
  )
  writeFile('nested/new.txt', 'new file\n')
  await callHook(
    'tool.execute.after',
    { callID: 'patch-new', tool: 'apply_patch' },
    { metadata: { files: [{ relativePath: 'nested/new.txt', type: 'add' }] } },
  )

  const absoluteFiles = ['alpha.txt', 'beta.txt', 'nested/new.txt'].map((file) => path.join(repo, file))
  state = queryNvim(absoluteFiles)

  if (!state.baseline) throw new Error(`Expected baseline ref; got ${JSON.stringify(state)}`)
  for (const file of ['alpha.txt', 'beta.txt', 'nested/new.txt']) assertIncludes(state.edited, file, 'edited files')
  for (const file of absoluteFiles) assertIncludes(state.turn, file, 'turn files')
  assertHunks(state, ['alpha.txt', 'beta.txt', 'nested/new.txt'])

  const alphaBaseline = run('git', ['show', `${state.baseline}:alpha.txt`])
  const betaBaseline = run('git', ['show', `${state.baseline}:beta.txt`])
  if (!alphaBaseline.includes('alpha old')) throw new Error(`Baseline did not preserve alpha old content: ${alphaBaseline}`)
  if (!betaBaseline.includes('beta old')) throw new Error(`Baseline did not preserve beta old content: ${betaBaseline}`)

  console.log(JSON.stringify({ ok: true, baseline: state.baseline, edited: state.edited, diffs: state.diffs }, null, 2))
} catch (error) {
  dumpDebug(error, state)
  throw error
}
