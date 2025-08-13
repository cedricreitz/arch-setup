if uwsm check may-start; then
    exec uwsm start hyprland-uwsm.desktop
fi

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

eval "$(zoxide init zsh)"
export ZSH="$HOME/.oh-my-zsh"

# Check if we're in a real TTY
if [[ $(tty) =~ /dev/tty[0-9]+ ]]; then
    ZSH_THEME="robbyrussell" 
else
    ZSH_THEME="powerlevel10k/powerlevel10k"
    [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
fi
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-autocomplete)

zstyle ':omz:update' mode auto      # update automatically without asking
# CASE_SENSITIVE="true"
# HYPHEN_INSENSITIVE="true"
ENABLE_CORRECTION="true"
plugins=(git zsh-autocomplete zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

alias cat="bat"
alias cd="z"
alias cl="clear"
alias ls="lsd"
