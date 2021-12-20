
" Setting <leader> key
let mapleader = " "

" This is necessary for VimTeX to load properly. The "indent" is optional.
" Note that most plugin managers will do this automatically.
filetype plugin indent on

" additional way to escape insert mode
imap jj <Esc>

syntax enable

set tabstop=4 softtabstop=4
set shiftwidth=4
set expandtab
set smartindent

set exrc
set guicursor=
set relativenumber
set nu
set nohlsearch
set hidden
set noerrorbells
set nowrap
set noswapfile
set nobackup
set incsearch
set termguicolors
set scrolloff=8
set noshowmode

set undodir=~/.vim/undodir
set undofile

set colorcolumn=88
set signcolumn=yes

set cmdheight=2
set updatetime=50

" install vim-plug if missing
let data_dir = has('nvim') ? stdpath('data') . '/site' : '~/.vim'
if empty(glob(data_dir . '/autoload/plug.vim'))
  silent execute '!curl -fLo '.data_dir.'/autoload/plug.vim --create-dirs  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" Specify a directory for plugins
" - For Neovim: stdpath('data') . '/plugged'
" - Avoid using standard Vim directory names like 'plugin'
call plug#begin('~/.vim/plugged')

" Make sure you use single quotes
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'gruvbox-community/gruvbox'

" Python black formatter
Plug 'psf/black', { 'branch': 'stable' }

" Latex support
Plug 'lervag/vimtex'


" Initialize plugin system
call plug#end()

colorscheme gruvbox
highlight Normal guibg=none

" Python Options:
autocmd FileType python nnoremap <leader>= :Black<CR>:w<CR>



" Latex Options
" " Viewer options: One may configure the viewer either by specifying a built-in
" viewer method:
let g:vimtex_view_method = 'zathura'
let maplocalleader = ","

nnoremap <leader>u :UndotreeShow<CR>
