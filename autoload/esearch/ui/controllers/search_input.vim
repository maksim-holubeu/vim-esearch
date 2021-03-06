let s:SelectionController = esearch#ui#controllers#selection#import()
let s:SearchPrompt        = esearch#ui#prompt#search#import()
let s:PathTitlePrompt     = esearch#ui#prompt#path_title#import()
let s:INF = 88888888

cnoremap <Plug>(esearch-cycle-regex)   <C-r>=<SID>interrupt('<SID>dispatch', 'NEXT_REGEX')<CR><CR>
cnoremap <Plug>(esearch-cycle-case)    <C-r>=<SID>interrupt('<SID>dispatch', 'NEXT_CASE')<CR><CR>
cnoremap <Plug>(esearch-cycle-textobj) <C-r>=<SID>interrupt('<SID>dispatch', 'NEXT_TEXTOBJ')<CR><CR>
cnoremap <Plug>(esearch-push-pattern)  <C-r>=<SID>interrupt('<SID>dispatch', 'PUSH_PATTERN')<CR><CR>
cnoremap <Plug>(esearch-open-menu)     <C-r>=<SID>interrupt('<SID>open_menu')<CR><CR>

cnoremap <expr> <Plug>(esearch-bs)  <SID>try_pop_pattern("\<bs>")
cnoremap <expr> <Plug>(esearch-c-w) <SID>try_pop_pattern("\<c-w>")
cnoremap <expr> <Plug>(esearch-c-h) <SID>try_pop_pattern("\<c-h>")

let s:self = {}
let s:SearchInputController = esearch#ui#component()

fu! s:SearchInputController.render() abort dict
  let s:self = self
  let original_mappings = esearch#keymap#restorable(g:esearch#cmdline#mappings)
  let original_options = self.set_options()
  try
    if self.props.live_update | call self.init_live_update() | endif
    return self.render_initial_selection() && self.render_input()
  catch /Vim:Interrupt/
    call self.props.dispatch({'type': 'SET_CMDLINE', 'cmdline': ''})
    call self.props.dispatch({'type': 'SET_LOCATION', 'location': 'exit'})
  finally
    if self.props.live_update | call self.uninit_live_update() | endif
    if !empty(original_options) | call original_options.restore() | endif
    call original_mappings.restore()
  endtry
endfu

fu! s:SearchInputController.set_options() dict abort
  let options = {'&synmaxcol': &columns} " prevent freezes on live_update

  let prompt = s:PathTitlePrompt.new().render()
  if !empty(prompt)
    let self.statusline = esearch#ui#to_statusline(prompt)
    let options['&statusline'] = self.statusline
  endif

  let restorable = esearch#let#restorable(options)
  if has_key(options, '&statusline') | redrawstatus! | endif

  return restorable
endfu

fu! s:SearchInputController.init_live_update() dict abort
  let self.executed_cmdline = ''

  aug esearch_live_update
    au!
    au CmdlineChanged * call s:live_update.apply()
    au OptionSet * if has_key(s:self, 'statusline') | let &statusline = s:self.statusline | endif
  aug END
  let s:live_update = esearch#async#debounce(function('s:live_update'),
        \ self.props.live_update_debounce_wait)
  
  call s:live_update.apply(self.props.pattern.peek().str)

  if self.props.win_update_throttle_wait > 0
    let timeout = self.props.win_update_throttle_wait
  else
    let timeout = self.props.live_update_debounce_wait
  endif
  let self.redraw_timer = timer_start(timeout, function('s:redraw'), {'repeat': -1})
endfu

fu! s:SearchInputController.final_live_update() dict abort
  " if changes were made and live_update_debounce_wait wasn't exceeded
  let cmdline = self.cmdline
  if s:self.executed_cmdline ==# cmdline || empty(cmdline) | return | endif
  call s:force_exec(cmdline)
endfu

fu! s:live_update(...) abort
  let cmdline = a:0 ? a:1 : getcmdline()
  if s:self.executed_cmdline ==# cmdline || empty(cmdline) || len(cmdline) < s:self.props.live_update_min_len
    return
  endif
  let s:self.executed_cmdline = cmdline
  let esearch = s:force_exec(cmdline)
  call s:self.props.dispatch({'type': 'SET_LIVE_UPDATE_BUFNR', 'bufnr': esearch.bufnr})
endfu

fu! s:force_exec(cmdline) abort
  let state = copy(s:self.__context__().store.state)
  call state.pattern.replace(a:cmdline)
  return esearch#init(extend(state, {'remember': [], 'force_exec': 1, 'name': '[esearch]' }))
endfu

fu! s:redraw(_) abort
  redraw
endfu

fu! s:SearchInputController.uninit_live_update() dict abort
  au! esearch_live_update *
  call timer_stop(self.redraw_timer)
endfu

fu! s:SearchInputController.render_initial_selection() abort dict
  if self.props.did_select_prefilled
    let self.cmdline = self.props.pattern.peek().str
  elseif !self.props.select_prefilled
    let self.cmdline = self.props.pattern.peek().str
    call self.props.dispatch({'type': 'SET_DID_SELECT_PREFILLED'})
  else
    if empty(self.props.pattern.peek().str)
      let self.cmdline = ''
    else
      " required if switched to esearch#init from another input()
      call esearch#ui#soft_clear()
      let [self.cmdline, finish, retype] = s:SelectionController.new().render()
      if finish
        if self.props.live_update | call self.final_live_update() | endif
        call self.props.dispatch({'type': 'SET_CMDLINE', 'cmdline': self.cmdline})
        call self.props.dispatch({'type': 'SET_LOCATION', 'location': 'exit'})
        return 0
      elseif !empty(retype)
        call feedkeys(retype)
      endif
    endif

    call self.props.dispatch({'type': 'SET_DID_SELECT_PREFILLED'})
  endif

  return 1
endfu

" redraw before is required here to clear possible output leftovers from multiline calls
fu! s:SearchInputController.render_input() abort
  call esearch#ui#soft_clear()

  let self.cmdline .= self.restore_cmdpos_chars()
  let self.pressed_mapped_key = 0
  let self.cmdline = self.input()

  if !empty(self.pressed_mapped_key)
    return call(self.pressed_mapped_key.handler, self.pressed_mapped_key.args)
  endif

  if self.props.live_update | call self.final_live_update() | endif
  call self.props.dispatch({'type': 'SET_CMDLINE', 'cmdline': self.cmdline})
  call self.props.dispatch({'type': 'SET_LOCATION', 'location': 'exit'})
endfu

fu! s:SearchInputController.input() abort dict
  " NOTE that it's impossible to properly retype keys (see SelectionController
  " for details) when inputsave() and inputrestore() are used.
  return input(esearch#ui#to_string(s:SearchPrompt.new()),
        \ substitute(self.cmdline, '\n', '\\n', 'g'), 'customlist,esearch#ui#complete#search#do')
endfu

fu! s:SearchInputController.restore_cmdpos_chars() abort
  if self.props.cmdpos == s:INF | return "\<End>" | endif
  return repeat("\<Left>", strchars(self.cmdline) + 1 - self.props.cmdpos)
endfu

fu! s:try_pop_pattern(fallback) abort
  if empty(getcmdline()) && len(s:self.props.pattern.patterns.list) > 1
    let s:self.pressed_mapped_key = {'handler': function('<SID>dispatch_try_pop_pattern'), 'args': a:000}
    call s:self.props.dispatch({'type': 'SET_CMDPOS', 'cmdpos': s:INF})
    return "\<cr>"
  endif

  return a:fallback
endfu

fu! s:dispatch_try_pop_pattern(...) abort
  call s:self.props.dispatch({'type': 'TRY_POP_PATTERN'})
endfu

fu! s:interrupt(func, ...) abort
  let s:self.pressed_mapped_key = {'handler': function(a:func), 'args': a:000}
  call s:self.props.dispatch({'type': 'SET_CMDPOS', 'cmdpos': getcmdpos()})
  return ''
endfu

fu! s:open_menu(...) abort dict
  call s:self.props.dispatch({'type': 'SET_CMDLINE', 'cmdline': s:self.cmdline})
  call s:self.props.dispatch({'type': 'SET_LOCATION', 'location': 'menu'})
endfu

fu! s:dispatch(event_type) abort dict
  call s:self.props.dispatch({'type': 'SET_CMDLINE', 'cmdline': s:self.cmdline})
  call s:self.props.dispatch({'type': a:event_type})
endfu

let s:map_state_to_props = esearch#util#slice_factory(['pattern', 'cmdpos',
      \ 'did_select_prefilled', 'select_prefilled', 'win_update_throttle_wait',
      \ 'live_update_debounce_wait', 'live_update', 'live_update_min_len'])

fu! esearch#ui#controllers#search_input#import() abort
  return esearch#ui#connect(s:SearchInputController, s:map_state_to_props)
endfu
