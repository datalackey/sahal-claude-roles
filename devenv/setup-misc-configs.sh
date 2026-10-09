#       This is a work in progress if we get back to scriptable nixos setup. Not used yet
#
rm -f $HOME/.vimrc
cp /etc/nixos/devenv/misc-configs/vim.rc  $HOME/.vimrc

rm -f $HOME/.ideavimrc
cp /etc/nixos/devenv/misc-configs/.ideavimrc $HOME/.ideavimrc

rm -rf $HOME/.vim
cp -r /etc/nixos/devenv/misc-configs/.vim $HOME/.vim


grep "config.bashrc"  ~/.bashrc
if [ "$?"  -eq  "0" ] ; then
        echo skipping bashrc config
else
        echo adding bashrc config
        echo ". \$HOME/config/bashrc" >> ~/.bashrc
fi

