let s:Prelude = vital#esearch#import('Prelude')

let g:asd = []
aug esearch_git
  au!
  au BufReadCmd esearchgit://* cal esearch#git#read_cmd(expand('<amatch>'))
aug END

fu! esearch#git#url(filename, dir) abort
  return 'esearchgit://' . simplify(a:dir) . '//' . simplify(a:filename)
endfu

fu! esearch#git#dir(cwd) abort
  return fnamemodify(esearch#util#find_up(a:cwd, ['.git/HEAD']), ':h')
endfu

fu! esearch#git#read_cmd(path) abort
  setlocal modifiable noswapfile buftype=nowrite undolevels=-1
  call esearch#util#doautocmd('BufReadPre')
  let [dir, filename] = split(a:path, '//')[1:2]
  let dir = s:Prelude.substitute_path_separator(shellescape(dir, 1))
  let filename = s:Prelude.substitute_path_separator(shellescape(filename, 1))
  " lockmarks to preserve the cursor location on open
  exe 'lockmarks 0read ++edit !git -C' dir 'cat-file -p' filename
  keepjumps silent $delete_
  setlocal nomodifiable readonly
  call esearch#util#doautocmd('BufReadPost')
endfu
