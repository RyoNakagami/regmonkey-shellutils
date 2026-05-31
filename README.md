


```zsh
# 1. Clone
git clone https://github.com/RyoNakagami/regmonkey-shellutils.git \
  ~/.local/share/regmonkey-shellutils

# 2. Add to ~/.zshrc
REGMONKEY_SHELLUTILS_PATH="$HOME/.local/share/regmonkey-shellutils"
_shellutils_root="${REGMONKEY_SHELLUTILS_PATH}/bin"
if [[ -d "${_shellutils_root}" ]]; then
  for _d in "${_shellutils_root}"/*/; do
    [[ -d "${_d}" ]] && export PATH="${_d%/}:$PATH"
  done
fi
unset _shellutils_root _d REGMONKEY_SHELLUTILS_PATH
```
