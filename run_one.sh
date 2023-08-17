#! /usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

BASH_PROFILE=$HOME/.bash_profile
if [ -f "$BASH_PROFILE" ]; then
    source $BASH_PROFILE
fi

TEST_LOG=test.log
TEST_DIR=test
cd $TEST_DIR
truncate -s 0 $TEST_LOG
FILES=`ls TestReqGenSQ.bsv`
for FILE in $FILES; do
    # echo $FILE
    TESTCASES=`grep -Phzo 'doc.*?\nmodule\s+\S+(?=\()' $FILE | xargs -0  -I {}  echo "{}" | grep module | cut -d ' ' -f 2`
    for TESTCASE in $TESTCASES; do
        make -j8 TESTFILE=$FILE TOPMODULE=$TESTCASE 2>&1 | tee -a $TEST_LOG
    done
done

###########################################################

FAIL_KEYWORKS='Error\|ImmAssert'
grep -w $FAIL_KEYWORKS $TEST_LOG | cat
ERR_NUM=`grep -c -w $FAIL_KEYWORKS $TEST_LOG | cat`
if [ $ERR_NUM -gt 0 ]; then
    echo "FAIL"
    false
else
    echo "PASS"
fi
