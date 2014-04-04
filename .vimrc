" source this file in your .vimrc to get the correct editor settings
" for openQA
let s:loc = expand('<sfile>:p:h')
function! ProjectOpenQA()
    " execute only if this function is called for files in the
    " openQA directory
    if stridx(expand('%:p'), s:loc) == 0
        set expandtab textwidth=0 shiftwidth=4
    endif
endfunction
autocmd! BufReadPost,BufNewFile * call ProjectOpenQA()
