local script_path = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ':p:h:h')

vim.opt.runtimepath:append(repo_root)
package.path = table.concat({
  repo_root .. '/lua/?.lua',
  repo_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local replay = require('nvim-claude.agent_provider.providers.codex.apply_patch_replay')

local function first_update_operation(patch)
  local operations, err = replay.parse_apply_patch_operations(patch)
  assert(type(operations) == 'table' and #operations > 0, 'parse failure: ' .. (err or 'no operations'))
  for _, op in ipairs(operations) do
    if op.type == 'update' then
      assert(op.hunks and #op.hunks > 0, 'update operation missing hunks')
      return op
    end
  end
  error('no update operation found in patch')
end

local function assert_equal(actual, expected, label, err)
  if actual ~= expected then
    error(string.format('[%s] expected %q but received %q (err=%s)', label, expected, actual, err or 'nil'))
  end
end

local tests = {
  {
    name = 'simple replacement',
    patch = table.concat({
      '*** Begin Patch',
      '*** Update File: cli_test.txt',
      '@@',
      '-hello',
      '+world',
      '*** End Patch',
    }, '\n'),
    final = 'world\n',
    expected = 'hello\n',
  },
  {
    name = 'multiple chunks',
    patch = table.concat({
      '*** Begin Patch',
      '*** Update File: multi.txt',
      '@@',
      '-line2',
      '+changed2',
      '@@',
      '-line4',
      '+changed4',
      '*** End Patch',
    }, '\n'),
    final = 'line1\nchanged2\nline3\nchanged4\n',
    expected = 'line1\nline2\nline3\nline4\n',
  },
  {
    name = 'rename move support',
    patch = table.concat({
      '*** Begin Patch',
      '*** Update File: old/name.txt',
      '*** Move to: renamed/dir/name.txt',
      '@@',
      '-old content',
      '+new content',
      '*** End Patch',
    }, '\n'),
    final = 'new content\n',
    expected = 'old content\n',
  },
  {
    name = 'pure addition at eof',
    patch = table.concat({
      '*** Begin Patch',
      '*** Update File: notes.txt',
      '@@',
      '+extra',
      '*** End Patch',
    }, '\n'),
    final = 'body\nextra\n',
    expected = 'body\n',
  },
  {
    name = 'pure deletion without context',
    patch = table.concat({
      '*** Begin Patch',
      '*** Update File: solo.txt',
      '@@',
      '-lonely',
      '*** End Patch',
    }, '\n'),
    final = '',
    expected = 'lonely\n',
  },
}

for _, test in ipairs(tests) do
  local operation = first_update_operation(test.patch)
  local restored, err = replay.reconstruct_prior_content(test.final, operation.hunks)
  assert_equal(restored, test.expected, test.name, err)
end

print(string.format('Codex apply_patch replay tests passed (%d scenarios)', #tests))
