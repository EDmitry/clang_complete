"
" File: clang_complete.vim
" Author: Xavier Deguillard <deguilx@gmail.com>
"
" Description: Use of clang to complete in C/C++.
"
" Help: Use :help clang_complete
"

au FileType c,cpp,objc,objcpp call <SID>ClangCompleteInit()

let b:clang_parameters = ''
let b:clang_user_options = ''
let b:my_changedtick = 0

" Store plugin path, as this is available only when sourcing the file,
" not during a function call.
let s:plugin_path = escape(expand('<sfile>:p:h'), '\')

function! s:ClangCompleteInit()
  let l:bufname = bufname("%")
  if l:bufname == ''
    return
  endif

  if exists('g:clang_use_library') && g:clang_use_library == 0
    echoe "clang_complete: You can't use clang binary anymore."
    echoe 'For more information see g:clang_use_library help.'
    return
  endif

  if !exists('g:clang_auto_select')
    let g:clang_auto_select = 0
  endif

  if !exists('g:clang_complete_auto')
    let g:clang_complete_auto = 1
  endif

  if !exists('g:clang_close_preview')
    let g:clang_close_preview = 0
  endif

  if !exists('g:clang_complete_copen')
    let g:clang_complete_copen = 0
  endif

  if !exists('g:clang_hl_errors')
    let g:clang_hl_errors = 1
  endif

  if !exists('g:clang_periodic_quickfix')
    let g:clang_periodic_quickfix = 0
  endif

  if !exists('g:clang_snippets')
    let g:clang_snippets = 0
  endif

  if !exists('g:clang_snippets_engine')
    let g:clang_snippets_engine = 'clang_complete'
  endif

  if !exists('g:clang_user_options')
    let g:clang_user_options = ''
  endif

  if !exists('g:clang_conceal_snippets')
    let g:clang_conceal_snippets = has('conceal')
  elseif g:clang_conceal_snippets == 1 && !has('conceal')
    echoe 'clang_complete: conceal feature not available but requested'
  endif

  if !exists('g:clang_trailing_placeholder')
    let g:clang_trailing_placeholder = 0
  endif

  if !exists('g:clang_compilation_database')
    let g:clang_compilation_database = ''
  endif

  if !exists('g:clang_library_path')
    let g:clang_library_path = ''
  endif

  if !exists('g:clang_complete_macros')
    let g:clang_complete_macros = 0
  endif

  if !exists('g:clang_complete_patterns')
    let g:clang_complete_patterns = 0
  endif

  if !exists('g:clang_debug')
    let g:clang_debug = 0
  endif

  if !exists('g:clang_sort_algo')
    let g:clang_sort_algo = 'priority'
  endif

  if !exists('g:clang_auto_user_options')
    let g:clang_auto_user_options = 'path, .clang_complete'
  endif

  call LoadUserOptions()

  let b:my_changedtick = b:changedtick
  let b:clang_parameters = '-x c'

  if &filetype == 'objc'
    let b:clang_parameters = '-x objective-c'
  endif

  if &filetype == 'cpp' || &filetype == 'objcpp'
    let b:clang_parameters .= '++'
  endif

  if expand('%:e') =~ 'h.*'
    let b:clang_parameters .= '-header'
  endif

  let g:clang_complete_lib_flags = 0

  if g:clang_complete_macros == 1
    let g:clang_complete_lib_flags = 1
  endif

  if g:clang_complete_patterns == 1
    let g:clang_complete_lib_flags += 2
  endif

  if s:initClangCompletePython() != 1
    return
  endif

  inoremap <expr> <buffer> <C-X><C-U> <SID>LaunchCompletion()
  inoremap <expr> <buffer> . <SID>CompleteDot()
  inoremap <expr> <buffer> > <SID>CompleteArrow()
  inoremap <expr> <buffer> : <SID>CompleteColon()
  inoremap <expr> <buffer> <CR> <SID>HandlePossibleSelectionEnter()
  nnoremap <expr> <buffer> <C-]> <SID>GotoDeclaration()

  if g:clang_snippets == 1
    call g:ClangSetSnippetEngine(g:clang_snippets_engine)
  endif

  " Force menuone. Without it, when there's only one completion result,
  " it can be confusing (not completing and no popup)
  if g:clang_auto_select != 2
    set completeopt-=menu
    set completeopt+=menuone
  endif

  " Disable every autocmd that could have been set.
  augroup ClangComplete
    autocmd!
  augroup end

  if g:clang_periodic_quickfix == 1
    augroup ClangComplete
      au CursorHold,CursorHoldI <buffer> call <SID>DoPeriodicQuickFix()
    augroup end
  endif

  setlocal completefunc=ClangComplete
  setlocal omnifunc=ClangComplete
endfunction

function! LoadUserOptions()
  let b:clang_user_options = ''

  let l:option_sources = split(g:clang_auto_user_options, ',')
  let l:remove_spaces_cmd = 'substitute(v:val, "\\s*\\(.*\\)\\s*", "\\1", "")'
  let l:option_sources = map(l:option_sources, l:remove_spaces_cmd)

  for l:source in l:option_sources
    if l:source == 'gcc' || l:source == 'clang'
      echo "'" . l:source . "' in clang_auto_user_options is deprecated."
      continue
    endif
    if l:source == 'path'
      call s:parsePathOption()
    elseif l:source == 'compile_commands.json'
      call s:findCompilationDatase(l:source)
    elseif l:source == '.clang_complete'
      call s:parseConfig()
    else
      let l:getopts = 'getopts#' . l:source . '#getopts'
      silent call eval(l:getopts . '()')
    endif
  endfor
endfunction

function! s:parseConfig()
  let l:local_conf = findfile('.clang_complete', getcwd() . ',.;')
  if l:local_conf == '' || !filereadable(l:local_conf)
    return
  endif

  let l:root = substitute(fnamemodify(l:local_conf, ':p:h'), '\', '/', 'g')

  let l:opts = readfile(l:local_conf)
  for l:opt in l:opts
    " Use forward slashes only
    let l:opt = substitute(l:opt, '\', '/', 'g')
    " Handling of absolute path
    if matchstr(l:opt, '\C-I\s*/') != ''
      let l:opt = substitute(l:opt, '\C-I\s*\(/\%(\w\|\\\s\)*\)',
            \ '-I' . '\1', 'g')
    elseif s:isWindows() && matchstr(l:opt, '\C-I\s*[a-zA-Z]:/') != ''
      let l:opt = substitute(l:opt, '\C-I\s*\([a-zA-Z:]/\%(\w\|\\\s\)*\)',
            \ '-I' . '\1', 'g')
    else
      let l:opt = substitute(l:opt, '\C-I\s*\(\%(\w\|\.\|/\|\\\s\)*\)',
            \ '-I' . l:root . '/\1', 'g')
    endif
    let b:clang_user_options .= ' ' . l:opt
  endfor
endfunction

function! s:findCompilationDatase(cdb)
  if g:clang_compilation_database == ''
    let l:local_conf = findfile(a:cdb, getcwd() . ',.;')
    if l:local_conf != '' && filereadable(l:local_conf)
      let g:clang_compilation_database = fnamemodify(l:local_conf, ":p:h")
    endif
  endif
endfunction

function! s:parsePathOption()
  let l:dirs = split(&path, ',')
  for l:dir in l:dirs
    if len(l:dir) == 0 || !isdirectory(l:dir)
      continue
    endif

    " Add only absolute paths
    if matchstr(l:dir, '\s*/') != ''
      let l:opt = '-I' . l:dir
      let b:clang_user_options .= ' ' . l:opt
    endif
  endfor
endfunction

function! s:initClangCompletePython()
  if !has('python')
    echoe 'clang_complete: No python support available.'
    echoe 'Cannot use clang library'
    echoe 'Compile vim with python support to use libclang'
    return 0
  endif

  " Only parse the python library once
  if !exists('s:libclang_loaded')
    python import sys

    exe 'python sys.path = ["' . s:plugin_path . '"] + sys.path'
    exe 'pyfile ' . fnameescape(s:plugin_path) . '/libclang.py'
    py vim.command('let l:res = ' + str(initClangComplete(vim.eval('g:clang_complete_lib_flags'), vim.eval('g:clang_compilation_database'), vim.eval('g:clang_library_path'))))
    if l:res == 0
      return 0
    endif
    let s:libclang_loaded = 1
  endif
  python WarmupCache()
  return 1
endfunction

function! s:DoPeriodicQuickFix()
  " Don't do any superfluous reparsing.
  if b:my_changedtick == b:changedtick
    return
  endif
  let b:my_changedtick = b:changedtick

  python updateCurrentDiagnostics()
  call s:ClangQuickFix()
endfunction

function! s:ClangQuickFix()
  " Clear the bad spell, the user may have corrected them.
  syntax clear SpellBad
  syntax clear SpellLocal

  python vim.command('let l:list = ' + str(getCurrentQuickFixList()))
  python highlightCurrentDiagnostics()

  if g:clang_complete_copen == 1
    " We should get back to the original buffer
    let l:bufnr = bufnr('%')

    " Workaround:
    " http://vim.1045645.n5.nabble.com/setqflist-inconsistency-td1211423.html
    if l:list == []
      cclose
    else
      copen
    endif

    let l:winbufnr = bufwinnr(l:bufnr)
    exe l:winbufnr . 'wincmd w'
  endif
  call setqflist(l:list)
  silent doautocmd QuickFixCmdPost make
endfunction

function! s:escapeCommand(command)
    return s:isWindows() ? a:command : escape(a:command, '()')
endfunction

function! s:isWindows()
  " Check for win32 is enough since it's true on win64
  return has('win32')
endfunction

let b:col = 0

function! ClangComplete(findstart, base)
  if a:findstart
    let l:line = getline('.')
    let l:start = col('.') - 1
    let l:wsstart = l:start
    if l:line[l:wsstart - 1] =~ '\s'
      while l:wsstart > 0 && l:line[l:wsstart - 1] =~ '\s'
        let l:wsstart -= 1
      endwhile
    endif
    while l:start > 0 && l:line[l:start - 1] =~ '\i'
      let l:start -= 1
    endwhile
    let b:col = l:start + 1
    return l:start
  else
    if g:clang_debug == 1
      let l:time_start = reltime()
    endif

    if g:clang_snippets == 1
      call b:ResetSnip()
    endif

    python completions, timer = getCurrentCompletions(vim.eval('a:base'))
    python vim.command('let l:res = ' + completions)
    python timer.registerEvent("Load into vimscript")

    for item in l:res
      if g:clang_snippets == 1
        let item['word'] = b:AddSnip(item['info'], item['args_pos'])
      else
        let item['word'] = item['abbr']
      endif
    endfor

    inoremap <expr> <buffer> <C-Y> <SID>HandlePossibleSelectionCtrlY()
    augroup ClangComplete
      au CursorMovedI <buffer> call <SID>TriggerSnippet()
    augroup end
    let b:snippet_chosen = 0

    python timer.registerEvent("vimscript + snippets")
    python timer.finish()

    if g:clang_debug == 1
      echom 'clang_complete: completion time ' . split(reltimestr(reltime(l:time_start)))[0]
    endif
    return l:res
  endif
endfunction

function! s:HandlePossibleSelectionEnter()
  if pumvisible()
    let b:snippet_chosen = 1
    return "\<C-Y>"
  end
  return "\<CR>"
endfunction

function! s:HandlePossibleSelectionCtrlY()
  if pumvisible()
    let b:snippet_chosen = 1
  end
  return "\<C-Y>"
endfunction

function! s:TriggerSnippet()
  " Dont bother doing anything until we're sure the user exited the menu
  if !b:snippet_chosen
    return
  endif

  if g:clang_snippets == 1
    " Stop monitoring as we'll trigger a snippet
    silent! iunmap <buffer> <C-Y>
    augroup ClangComplete
      au! CursorMovedI <buffer>
    augroup end

    " Trigger the snippet
    call b:TriggerSnip()
  endif

  if g:clang_close_preview
    pclose
  endif
endfunction

function! s:ShouldComplete()
  if (getline('.') =~ '#\s*\(include\|import\)')
    return 0
  else
    if col('.') == 1
      return 1
    endif
    for l:id in synstack(line('.'), col('.') - 1)
      if match(synIDattr(l:id, 'name'), '\CComment\|String\|Number')
            \ != -1
        return 0
      endif
    endfor
    return 1
  endif
endfunction

function! s:LaunchCompletion()
  let l:result = ""
  if s:ShouldComplete()
    let l:result = "\<C-X>\<C-U>"
    if g:clang_auto_select != 2
      let l:result .= "\<C-P>"
    endif
    if g:clang_auto_select == 1
      let l:result .= "\<C-R>=(pumvisible() ? \"\\<Down>\" : '')\<CR>"
    endif
  endif
  return l:result
endfunction

function! s:CompleteDot()
  if g:clang_complete_auto == 1
    return '.' . s:LaunchCompletion()
  endif
  return '.'
endfunction

function! s:CompleteArrow()
  if g:clang_complete_auto != 1 || getline('.')[col('.') - 2] != '-'
    return '>'
  endif
  return '>' . s:LaunchCompletion()
endfunction

function! s:CompleteColon()
  if g:clang_complete_auto != 1 || getline('.')[col('.') - 2] != ':'
    return ':'
  endif
  return ':' . s:LaunchCompletion()
endfunction

function! s:GotoDeclaration()
  " I would like to mimic <C-]> and <C-T> when using tags.
  " It would be much easier if the tag stack could be modified, but alas
  " that is not possible. All the handling should be done by hand...
  python gotoDeclaration()
  return ''
endfunction

" May be used in a mapping to update the quickfix window.
function! g:ClangUpdateQuickFix()
  call s:DoPeriodicQuickFix()
  return ''
endfunction

function! g:ClangSetSnippetEngine(engine_name)
  try
    call eval('snippets#' . a:engine_name . '#init()')
    let b:AddSnip = function('snippets#' . a:engine_name . '#add_snippet')
    let b:ResetSnip = function('snippets#' . a:engine_name . '#reset')
    let b:TriggerSnip = function('snippets#' . a:engine_name . '#trigger')
  catch /^Vim\%((\a\+)\)\=:E117/
    echoe 'Snippets engine ' . a:engine_name . ' not found.'
    let g:clang_snippets = 0
  endtry
endfunction

" vim: set ts=2 sts=2 sw=2 expandtab :
