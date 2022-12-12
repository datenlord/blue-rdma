#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

BASH_PROFILE=$HOME/.bash_profile
if [ -f "$BASH_PROFILE" ]; then
    source $BASH_PROFILE
fi

cd test

RUN_LOG=run.log
echo "" > $RUN_LOG

make -j8 TESTFILE=SimDma.bsv TOP=mkTestFixedLenSimDataStreamPipeOut 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=SimGenRdmaResp.bsv TOP=mkTestSimGenRdmaResp 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestHeaderAndDataStreamConversion 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestPrependHeaderBeforeEmptyDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractHeaderWithLessThanOneFragPayload 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractHeaderLongerThanDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractAndPrependHeader 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculateRandomPktLen 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculatePktLenEqPMTU 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculateZeroPktLen 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestReqGenSQ.bsv TOP=mkTestReqGenSQ 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestScanFIFOF.bsv TOP=mkTestScanFIFOF 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestWorkCompHandler.bsv TOP=mkTestWorkCompHandlerNormalCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestUtils.bsv TOP=mkTestSegmentDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestUtils.bsv TOP=mkTestPsnFunc 2>&1 | tee -a $RUN_LOG

FAIL_KEYWORKS='Error\|DynAssert'
grep -w $FAIL_KEYWORKS $RUN_LOG | cat
ERR_NUM=`grep -c -w $FAIL_KEYWORKS $RUN_LOG | cat`
if [ $ERR_NUM -gt 0 ]; then
    echo "FAIL"
    false
else
    echo "PASS"
fi
