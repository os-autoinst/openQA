" source this file in your .vimrc to get the correct editor settings
" for openQA
function! ProjectOpenQA()
    " execute only if this function is called for files in the
    " openQA directory
    if stridx(expand('%:p'), expand('<sfile>:p:h')) == 0
        set expandtab textwidth=0 shiftwidth=4
    endif
endfunction
autocmd! BufReadPost,BufNewFile * call ProjectOpenQA()
