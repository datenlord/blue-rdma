#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

BASH_PROFILE=$HOME/.bash_profile
if [ -f "$BASH_PROFILE" ]; then
    source $BASH_PROFILE
fi

TEST_DIR=`realpath ./test`
LOG_DIR=`realpath ./tmp`
ALL_LOG=$TEST_DIR/run.log

mkdir -p $LOG_DIR
#cd $TEST_DIR
# echo "" > $ALL_LOG

# make -j8 TESTFILE=SimDma.bsv TOPMODULE=mkTestFixedPktLenDataStreamPipeOut 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=SimDma.bsv TOPMODULE=mkTestDmaReadAndWriteSrv 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=SimExtractHeaderRDMAPayload.bsv TOPMODULE=mkTestSimExtractNormalHeaderPayload 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=SimGenRdmaReqResp.bsv TOPMODULE=mkTestSimGenRdmaResp 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestArbitration.bsv TOPMODULE=mkTestPipeOutArbiter 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestArbitration.bsv TOPMODULE=mkTestServerArbiter 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestArbitration.bsv TOPMODULE=mkTestClientArbiter 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestController.bsv TOPMODULE=mkTestCntrlInVec 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestDupReadAtomicCache.bsv TOPMODULE=mkTestDupReadAtomicCache 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestDupReadAtomicCache.bsv TOPMODULE=mkTestCacheFIFO 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOPMODULE=mkTestHeaderAndDataStreamConversion 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOPMODULE=mkTestPrependHeaderBeforeEmptyDataStream 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOPMODULE=mkTestExtractHeaderWithPayloadLessThanOneFrag 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOPMODULE=mkTestExtractHeaderLongerThanDataStream 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOPMODULE=mkTestExtractAndPrependHeader 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestInputPktHandle.bsv TOPMODULE=mkTestCalculateRandomPktLen 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestInputPktHandle.bsv TOPMODULE=mkTestCalculatePktLenEqPMTU 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestInputPktHandle.bsv TOPMODULE=mkTestCalculateZeroPktLen 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestInputPktHandle.bsv TOPMODULE=mkTestReceiveCNP 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestMetaDataMRs 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestMetaDataPDs 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestMetaDataQPs 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestPermCheckMR 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestMetaDataSrv 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestBramCache 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestMetaData.bsv TOPMODULE=mkTestTLB 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestAddrChunkSrv 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestDmaReadCntrlNormalCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestDmaReadCntrlCancelCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestDmaWriteCntrlNormalCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestDmaWriteCntrlCancelCase 2>&1 | tee -a $ALL_LOG
## make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestDmaWriteCntrl 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestPayloadConNormalCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestPayloadCon.bsv TOPMODULE=mkTestPayloadGenSegmentAndPaddingCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestPermCheckCltArbiter 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestDmaReadCltArbiter 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestQueuePairReqErrResetCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestQueuePairRespErrResetCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestQueuePairTimeOutErrResetCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestQueuePairTimeOutErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestQueuePair.bsv TOPMODULE=mkTestQueuePairNormalCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestReqGenSQ.bsv TOPMODULE=mkTestReqGenNormalCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqGenSQ.bsv TOPMODULE=mkTestReqGenZeroLenCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqGenSQ.bsv TOPMODULE=mkTestReqGenDmaReadErrCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleNormalReqCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleDupReqCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleNoAckReqCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleTooManyReadAtomicReqCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleReqErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandlePermCheckFailCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleDmaReadErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleRnrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestReqHandleRQ.bsv TOPMODULE=mkTestReqHandleSeqErrCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleNormalRespCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleDupRespCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleGhostRespCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleRespErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleRetryErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleTimeOutErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandlePermCheckFailCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleRnrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleSeqErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRespHandleSQ.bsv TOPMODULE=mkTestRespHandleNestedRetryCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleSeqErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleImplicitRetryCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleRnrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleTimeOutCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleNestedRetryCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleExcRetryLimitErrCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestRetryHandleSQ.bsv TOPMODULE=mkTestRetryHandleExcTimeOutLimitErrCase 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestSpecialFIFOF.bsv TOPMODULE=mkTestCacheFIFO2 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestSpecialFIFOF.bsv TOPMODULE=mkTestScanFIFOF 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestSpecialFIFOF.bsv TOPMODULE=mkTestSearchFIFOF 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestSpecialFIFOF.bsv TOPMODULE=mkTestVectorSearch 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestTransportLayer.bsv TOPMODULE=mkTestTransportLayerNormalCase 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestTransportLayer.bsv TOPMODULE=mkTestTransportLayerErrorCase 2>&1 | tee -a $ALL_LOG

## make -j8 TESTFILE=TestUtils.bsv TOPMODULE=mkTestSegmentDataStream 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestUtils.bsv TOPMODULE=mkTestPsnFunc 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestWorkCompGen.bsv TOPMODULE=mkTestWorkCompGenNormalCaseRQ 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestWorkCompGen.bsv TOPMODULE=mkTestWorkCompGenErrFlushCaseRQ 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestWorkCompGen.bsv TOPMODULE=mkTestWorkCompGenNormalCaseSQ 2>&1 | tee -a $ALL_LOG
# make -j8 TESTFILE=TestWorkCompGen.bsv TOPMODULE=mkTestWorkCompGenErrFlushCaseSQ 2>&1 | tee -a $ALL_LOG

# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestCalcPktNumAndPktLenByAddrAndPMTU
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestAddrChunkSrv
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestDmaReadCntrlScatterGatherListCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestDmaReadCntrlNormalCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestDmaReadCntrlCancelCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestMergeNormalPayloadEachSGE
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestMergeSmallPayloadEachSGE
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestMergeNormalPayloadAllSGE
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestMergeSmallPayloadAllSGE
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestAdjustNormalPayloadSegmentCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestAdjustSmallPayloadSegmentCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestPayloadGenNormalCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestPayloadGenSmallCase
# make -j8 TESTFILE=TestPayloadGen.bsv TOPMODULE=mkTestPayloadGenZeroCase

# make -j8 TESTFILE=TestSendQ.bsv TOPMODULE=mkTestSendQueueRawPktCase
# make -j8 TESTFILE=TestSendQ.bsv TOPMODULE=mkTestSendQueueNormalCase
# make -j8 TESTFILE=TestSendQ.bsv TOPMODULE=mkTestSendQueueNoPayloadCase
# make -j8 TESTFILE=TestSendQ.bsv TOPMODULE=mkTestSendQueueZeroPayloadLenCase

make -j8 -f Makefile.test all TESTDIR=$TEST_DIR LOGDIR=$LOG_DIR
cat $LOG_DIR/*.log | tee $ALL_LOG

FAIL_KEYWORKS='Error\|ImmAssert'
grep -w $FAIL_KEYWORKS $LOG_DIR/*.log | cat
ERR_NUM=`grep -c -w $FAIL_KEYWORKS $ALL_LOG | cat`
if [ $ERR_NUM -gt 0 ]; then
    echo "FAIL"
    false
else
    echo "PASS"
fi
