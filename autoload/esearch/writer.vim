let s:Prelude = vital#esearch#import('Prelude')
let s:List = vital#esearch#import('Data.List')
let s:Buf = esearch#buf#handle()
let s:by_key = function('esearch#util#by_key')

fu! esearch#writer#do(diffs, esearch, bang) abort
  return s:Writer.new(a:diffs, a:esearch).write(a:bang)
endfu

let s:Writer = {}

fu! s:Writer.new(diffs, esearch) abort dict
  return extend(deepcopy(self), {
        \ 'diffs': a:diffs,
        \ 'esearch': a:esearch,
        \ 'search_buf': s:Buf.for(a:esearch.bufnr),
        \ 'win_edits': [],
        \ 'win_undos': [],
        \ 'renames':   [],
        \ 'conflicts': [],
        \})
endfu

fu! s:Writer.write(bang) abort dict
  let [contexts, WriteCb] = [self.esearch.contexts, self.esearch.write_cb]
  let [current_window, current_buffer, view] = [esearch#win#stay(), esearch#buf#stay(), winsaveview()]

  call esearch#util#doautocmd('User esearch_write_pre')
 " Wipeout preview buffer if was viewed ignoring swap to prevent missing
 " swapexists messages later
  call esearch#preview#wipeout()
  aug esearch_write
    au!
    au SwapExists * let v:swapchoice = 'q'
  aug END
  try
    for [id, diff] in sort(items(self.diffs.by_id), s:by_key)
      let path = esearch#out#win#view_data#filename(self.esearch, diff.ctx)
      if !self.verify_readable(diff, path) | continue | endif

      try
        let buf = s:Buf.new(path)
      catch /E325:/ " swapexists exception, will be handled by v:swapchoice set above
        call self.handle_existing_swap(path)
        continue
      endtry
      if !a:bang
        if !self.verify_not_modified(diff, buf) | continue | endif
      endif

      let self.win_edits = diff.win_edits + self.win_edits
      let self.win_undos = self.update_file(buf, diff) + self.win_undos
      let contexts[diff.ctx.id].lines = diff.lines_b
      let contexts[diff.ctx.id].begin = diff.begin

      if has_key(diff, 'filename')
        call add(self.renames, [buf, contexts[diff.ctx.id], diff.filename])
      endif

      if !empty(WriteCb) | call WriteCb(buf, a:bang) | endif
    endfor
    call self.rename(a:bang)
  finally
    au! esearch_write
    call current_window.restore()
    call current_buffer.restore()
    call self.create_undo_entry()
    call winrestview(view)
  endtry
  call self.log()
  " Deferring is required to execute the autocommand with avoiding BufWriteCmd side effects
  call esearch#util#try_defer(function('esearch#util#doautocmd'), 'User esearch_write_post')
endfu

fu! s:Writer.rename(bang) abort
  for [buf, ctx_a, relative_filename_b] in self.renames
    let filename_a = simplify(esearch#util#abspath(self.esearch.cwd, ctx_a.filename))
    let filename_b = simplify(esearch#util#abspath(self.esearch.cwd, relative_filename_b))
    let filename_a = s:Prelude.substitute_path_separator(filename_a)
    let dir_b = s:Prelude.substitute_path_separator(fnamemodify(filename_b, ':h'))
    let filename_b = s:Prelude.substitute_path_separator(filename_b)

    if isdirectory(filename_b)
      call add(self.conflicts, [relative_filename_b, "can't overwite the directory"])
      continue
    endif

    if !a:bang && esearch#util#file_exists(filename_b)
      if !has_key(g:, 'esearch_overwrite')
            \ && confirm(filename_b . ' exists. Overwrite?', "&Yes\n&Cancel") == 2
            \ || !g:esearch_overwrite
        continue
      endif
    endif

    call mkdir(dir_b, 'p')
    if rename(filename_a, filename_b) !=# 0
      call add(self.conflicts, [relative_filename_b, 'rename() has failed'])
      continue
    endif

    if bufloaded(buf.bufnr)
      let hidden = esearch#let#restorable({'&l:hidden': 1})
      silent call buf.bufdo('silent! saveas! '.fnameescape(filename_b) . '| bdelete! # ')
      call hidden.restore()
    endif

    let ctx_a.filename = relative_filename_b
  endfor
endfu

fu! s:Writer.create_undo_entry() abort dict
  let original_register = @s
  try
    call self.update_win(self.win_edits)
    let latest_state = self.esearch.state
    silent! %yank s

    exe 'undo' self.esearch.undotree.written.changenr
    call self.update_win(self.win_undos)
    let undone_state = self.esearch.undotree.written.state
    call self.esearch.undotree.squash(undone_state)
    call esearch#util#squash_undo()
    keepjumps %delete _
    keepjumps %put s
    keepjumps 1delete _

    let b:esearch.state = b:esearch.undotree.commit(latest_state)
    call self.esearch.undotree.on_write()
  finally
    let @s = original_register
  endtry
endfu

fu! s:Writer.update_file(buf, diff) abort
  let edits = a:diff.edits
  if empty(edits) | return a:diff.win_undos | endif

  for edit in edits[:-2]
    call call(a:buf[edit.func], edit.args)
  endfor

  if edits[-1].func ==# 'deleteline' && a:buf.oneliner()
    let a:diff.win_undos[0].args[1][-1] =
          \ substitute(a:diff.win_undos[0].args[1][-1], g:esearch#out#win#capture_sign_re, '_', '')
  endif

  call call(a:buf[edits[-1].func], edits[-1].args)

  return a:diff.win_undos
endfu

fu! s:Writer.update_win(win_edits) abort
  for edit in a:win_edits
    call call(self.search_buf[edit.func], edit.args)
  endfor
endfu

fu! s:Writer.handle_existing_swap(path) abort dict
  call add(self.conflicts, [a:path, 'swapfile exists'])

  if bufexists(a:path)
    let bufnr = esearch#buf#find(a:path)
    let bufname = simplify(resolve(bufname(bufnr)))
    " Delete ONLY buffer we've loaded to reload swapchoice prompt
    if bufname ==# simplify(resolve(a:path))
      exe bufnr . 'bdelete'
    endif
  endif
endfu

fu! s:Writer.log() abort dict
  if empty(self.conflicts)
    call esearch#util#warn('Done.')
    return setbufvar(self.esearch.bufnr, '&modified', 0)
  end

  let reasons = map(self.conflicts, 'printf("\n  %s (%s)", v:val[0], v:val[1])')
  let message = "Can't apply changes for following files:".join(reasons, '')
  call esearch#util#warn(message)
endfu

fu! s:Writer.verify_readable(diff, path) abort dict
  if filereadable(a:path) | return 1 | endif
  if get(a:diff.ctx, 'rev')
    call add(self.conflicts, [a:path, 'is a git blob'])
  else
    call add(self.conflicts, [a:path, 'is not readable'])
  endif
  return 0
endfu

fu! s:Writer.verify_not_modified(diff, buf) abort dict
  let ours_lines = a:diff.ctx.lines
  for edit in a:diff.edits
    if !has_key(ours_lines, edit.args[0]) || a:buf.getline(edit.args[0]) is# ours_lines[edit.args[0]]
      continue
    endif

    call add(self.conflicts, [a:diff.ctx.filename, 'line '.edit.args[0].' has changed'])
    return 0
  endfor

  return 1
endfu
