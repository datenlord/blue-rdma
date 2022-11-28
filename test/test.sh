#! /bin/sh

set -o errexit
set -o nounset
set -o xtrace

FAIL_KEYWORK=failed
RUN_LOG=run.log

echo "" > $RUN_LOG

make TESTFILE=SimDmaHandler.bsv TOP=mkTestFixedLenSimDataStreamPipeOut 2>&1 | tee -a $RUN_LOG
make TESTFILE=TestUtils.bsv TOP=mkTestSegmentDataStream 2>&1 | tee -a $RUN_LOG
make TESTFILE=TestUtils.bsv TOP=mkTestPsnFunc 2>&1 | tee -a $RUN_LOG

make TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractHeaderLongerThanDataStream 2>&1 | tee -a $RUN_LOG
make TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractAndPrependHeader 2>&1 | tee -a $RUN_LOG
# make TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestHeaderAndDataStreamConversion 2>&1 | tee -a $RUN_LOG

grep $FAIL_KEYWORK $RUN_LOG | cat
ERR_NUM=`grep -c $FAIL_KEYWORK $RUN_LOG | cat`
if [ $ERR_NUM -gt 0 ]; then
    echo "FAIL"
    false
else
    echo "PASS"
fi
