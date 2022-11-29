#! /bin/sh

set -o errexit
set -o nounset
set -o xtrace

rm -rf bsc-*
wget https://github.com/B-Lang-org/bsc/releases/download/2022.01/bsc-2022.01-ubuntu-20.04.tar.gz
tar zxf bsc-*

BSC_FILE_NAME=`ls bsc-*.tar.gz`
BSC_DIR_NAME=`basename $BSC_FILE_NAME .tar.gz`
BLUESPEC_HOME=`realpath $BSC_DIR_NAME`

BASH_PROFILE=$HOME/.bash_profile
touch $BASH_PROFILE
cat <<EOF >> $BASH_PROFILE
# BSV required env
export BLUESPECDIR=$BLUESPEC_HOME/lib
export PATH=$PATH:$BLUESPEC_HOME/bin
EOF
