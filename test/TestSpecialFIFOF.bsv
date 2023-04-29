import Cntrs :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import SpecialFIFOF :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;
import Utils4Test :: *;

typedef Bit#(64) ItemType;

typedef enum {
    TEST_SCAN_Q_FILL,
    TEST_SCAN_Q_PRE_SCAN,
    TEST_SCAN_Q_SCAN,
    TEST_SCAN_Q_PRE_SCAN_AGAIN,
    TEST_SCAN_Q_SCAN_POP
} ScanFifoTestState deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestScanFIFOF(Empty);
    ScanFIFOF#(MAX_QP_WR, ItemType) scanQ <- mkScanFIFOF;
    PipeOut#(ItemType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ItemType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4DeqRef       <- mkBufferN(valueOf(MAX_QP_WR), qElemPipeOutVec[1]);
    let qElemPipeOut4ScanRef      <- mkSizedFIFOF(valueOf(MAX_QP_WR));
    let qElemPipeOut4ScanAgainRef <- mkBufferN(valueOf(MAX_QP_WR), qElemPipeOutVec[2]);

    Count#(Bit#(TAdd#(1, TLog#(MAX_QP_WR)))) scanCnt <- mkCount(0);
    Reg#(ScanFifoTestState) scanTestStateReg <- mkReg(TEST_SCAN_Q_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule fillScanQ if (scanTestStateReg == TEST_SCAN_Q_FILL);
        if (scanQ.fifof.notFull) begin
            let curEnqData = qElemPipeOut4Q.first;
            qElemPipeOut4Q.deq;

            scanQ.fifof.enq(curEnqData);
            qElemPipeOut4ScanRef.enq(curEnqData);
            // $display(
            //     "time=%0t: curEnqData=%h when in fill mode",
            //     $time, curEnqData
            // );
        end
        else begin
            scanQ.scanCntrl.preScanStart;
            scanTestStateReg <= TEST_SCAN_Q_PRE_SCAN;
            // $display(
            //     "time=%0t:", $time,
            //     " change to state=", fshow(TEST_SCAN_Q_PRE_SCAN)
            // );
        end
        // $display(
        //     "time=%0t:", $time,
        //     " scanQ.fifof.notFull=", fshow(scanQ.fifof.notFull)
        // );
    endrule

    rule preScan if (scanTestStateReg == TEST_SCAN_Q_PRE_SCAN);
        scanQ.scanCntrl.scanStart;
        scanTestStateReg <= TEST_SCAN_Q_SCAN;
        // Set scanCnt to half queue length
        scanCnt <= fromInteger(valueOf(TDiv#(MAX_QP_WR, 2)));
        // $display(
        //     "time=%0t:", $time,
        //     " preScan change to state=", fshow(TEST_SCAN_Q_SCAN)
        // );
    endrule

    rule compareScan if (scanTestStateReg == TEST_SCAN_Q_SCAN);
        if (isOne(scanCnt)) begin
            scanQ.scanCntrl.preScanRestart;
            scanTestStateReg <= TEST_SCAN_Q_PRE_SCAN_AGAIN;
            // $display(
            //     "time=%0t:", $time,
            //     " compareScan change to state=", fshow(TEST_SCAN_Q_PRE_SCAN_AGAIN)
            // );
        end

        let curScanData = scanQ.scanPipeOut.first;
        scanQ.scanPipeOut.deq;

        let refScanData = qElemPipeOut4ScanRef.first;
        qElemPipeOut4ScanRef.deq;

        immAssert(
            curScanData == refScanData,
            "curScanData assertion @ mkTestScanFIFOF",
            $format(
                "curScanData=%h should == refScanData=%h when in scan mode",
                curScanData, refScanData
            )
        );

        scanCnt.decr(1);
        // $display(
        //     "time=%0t:", $time, " scanCnt=%0d", scanCnt,
        //     " curScanData=%h should == refScanData=%h when in scan mode",
        //     curScanData, refScanData
        // );
    endrule

    rule preScanAgain if (scanTestStateReg == TEST_SCAN_Q_PRE_SCAN_AGAIN);
        scanQ.scanCntrl.scanStart;
        scanTestStateReg <= TEST_SCAN_Q_SCAN_POP;
        qElemPipeOut4ScanRef.clear;
        // $display(
        //     "time=%0t:", $time,
        //     " preScanAgain change to state=", fshow(TEST_SCAN_Q_SCAN_POP)
        // );
    endrule

    rule compareScanAgain if (scanTestStateReg == TEST_SCAN_Q_SCAN_POP);
        let curScanData = scanQ.scanPipeOut.first;
        scanQ.scanPipeOut.deq;

        let refScanData = qElemPipeOut4ScanAgainRef.first;
        qElemPipeOut4ScanAgainRef.deq;

        immAssert(
            curScanData == refScanData,
            "curScanData assertion @ mkTestScanFIFOF",
            $format(
                "curScanData=%h should == refScanData=%h when in scan mode again",
                curScanData, refScanData
            )
        );
        // $display(
        //     "time=%0t: curScanData=%h should == refScanData=%h when in scan mode again",
        //     $time, curScanData, refScanData
        // );
    endrule

    rule compareDeq if (scanTestStateReg == TEST_SCAN_Q_SCAN_POP);
        if (scanQ.fifof.notEmpty) begin
            countDown.decr;

            let curDeqData = scanQ.fifof.first;
            scanQ.fifof.deq;

            let refDeqData = qElemPipeOut4DeqRef.first;
            qElemPipeOut4DeqRef.deq;

            immAssert(
                curDeqData == refDeqData,
                "curDeqData assertion @ mkTestScanFIFOF",
                $format(
                    "curDeqData=%h should == refDeqData=%h when dequeue",
                    curDeqData, refDeqData
                )
            );
            // $display(
            //     "time=%0t: curDeqData=%h should == refDeqData=%h when dequeue",
            //     $time, curDeqData, refDeqData
            // );
        end
        else begin
            scanTestStateReg <= TEST_SCAN_Q_FILL;
        end
    endrule
endmodule

typedef enum {
    TEST_Q_FILL,
    TEST_Q_ACT,
    TEST_Q_POP
} FifoTestState deriving(Bits, Eq);

(* synthesize *)
module mkTestSearchFIFOF(Empty);
    SearchFIFOF#(MAX_QP_RD_ATOM, ItemType) searchQ <- mkSearchFIFOF;
    Count#(Bit#(TLog#(MAX_QP_RD_ATOM))) itemCnt <- mkCount(0);

    PipeOut#(ItemType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ItemType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4DeqRef    <- mkBufferN(valueOf(MAX_QP_RD_ATOM), qElemPipeOutVec[1]);
    let qElemPipeOut4SearchRef <- mkBufferN(valueOf(MAX_QP_RD_ATOM), qElemPipeOutVec[2]);
    Reg#(FifoTestState) searchTestStateReg <- mkReg(TEST_Q_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function Bool searchFunc(ItemType searchItem, ItemType fifoItem) = searchItem == fifoItem;

    rule fillSearchQ if (searchTestStateReg == TEST_Q_FILL);
        if (searchQ.fifof.notFull) begin
            let curEnqData = qElemPipeOut4Q.first;
            qElemPipeOut4Q.deq;

            searchQ.fifof.enq(curEnqData);
            $display(
                "time=%0t: curEnqData=%h when in fill mode",
                $time, curEnqData
            );
        end
        else begin
            searchTestStateReg <= TEST_Q_ACT;
            itemCnt <= 0;
        end
    endrule

    rule compareSearch if (searchTestStateReg == TEST_Q_ACT);
        if (isAllOnes(itemCnt)) begin
            itemCnt <= 0;
            searchTestStateReg <= TEST_Q_POP;
        end
        else begin
            itemCnt.incr(1);
        end

        let refSearchData = qElemPipeOut4SearchRef.first;
        qElemPipeOut4SearchRef.deq;

        let maybeFindData = searchQ.searchIfc.search(searchFunc(refSearchData));
        immAssert(
            isValid(maybeFindData),
            "maybeFindData assertion @ mkTestSearchFIFOF",
            $format(
                "maybeFindData=", fshow(maybeFindData),
                " should be valid when refSearchData=%h and itemCnt=%0d",
                refSearchData, itemCnt
            )
        );

        let curSearchData = unwrapMaybe(maybeFindData);
        immAssert(
            curSearchData == refSearchData,
            "curSearchData assertion @ mkTestSearchFIFOF",
            $format(
                "curSearchData=%h should == refSearchData=%h when itemCnt=%0d",
                curSearchData, refSearchData, itemCnt
            )
        );
        // $display(
        //     "time=%0t: curSearchData=%h should == refSearchData=%h when itemCnt=%0d",
        //     $time, curSearchData, refSearchData, itemCnt
        // );
    endrule

    rule compareDeq if (searchTestStateReg == TEST_Q_POP);
        if (searchQ.fifof.notEmpty) begin
            countDown.decr;

            let curDeqData = searchQ.fifof.first;
            searchQ.fifof.deq;

            let refDeqData = qElemPipeOut4DeqRef.first;
            qElemPipeOut4DeqRef.deq;

            immAssert(
                curDeqData == refDeqData,
                "curDeqData assertion @ mkTestSearchFIFOF",
                $format(
                    "curDeqData=%h should == refDeqData=%h when in deq mode",
                    curDeqData, refDeqData
                )
            );
            // $display(
            //     "time=%0t: curDeqData=%h should == refDeqData=%h when in deq mode",
            //     $time, curDeqData, refDeqData
            // );
        end
        else begin
            searchTestStateReg <= TEST_Q_FILL;
        end
    endrule
endmodule

(* synthesize *)
module mkTestCacheFIFO2(Empty);
    function Tuple2#(Bool, ItemType) compareFunc(ItemType item4Search, ItemType itemInQ);
        return tuple2(item4Search == itemInQ, itemInQ);
    endfunction

    function Bool checkCompareResult(Tuple2#(Bool, ItemType) searchResult);
        return getTupleFirst(searchResult);
    endfunction

    CacheFIFO#(MAX_QP_RD_ATOM, ItemType) cacheQ <- mkCacheFIFO2(
        compareFunc, checkCompareResult, getTupleSecond
    );

    PipeOut#(ItemType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ItemType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4SearchReq <- mkBufferN(2, qElemPipeOutVec[1]);
    let qElemPipeOut4SearchResp <- mkBufferN(2, qElemPipeOutVec[2]);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // function Bool searchFunc(ItemType searchItem, ItemType fifoItem);
    //     return searchItem == fifoItem;
    // endfunction

    rule pushCacheQ;
        let curEnqData = qElemPipeOut4Q.first;
        qElemPipeOut4Q.deq;

        cacheQ.cacheIfc.push(curEnqData);
        // $display(
        //     "time=%0t: curEnqData=%h when in fill mode",
        //     $time, curEnqData
        // );
    endrule

    rule searchReq;
        let searchData = qElemPipeOut4SearchReq.first;
        qElemPipeOut4SearchReq.deq;

        cacheQ.searchIfc.searchReq(searchData);
    endrule

    rule compareSearchResp;
        countDown.decr;

        let searchResult <- cacheQ.searchIfc.searchResp;

        let refSearchData = qElemPipeOut4SearchResp.first;
        qElemPipeOut4SearchResp.deq;

        immAssert(
            isValid(searchResult),
            "searchResult assertion @ mkTestCacheFIFO",
            $format(
                "searchResult=", fshow(searchResult),
                " should be valid"
            )
        );

        let searchData = unwrapMaybe(searchResult);
        immAssert(
            searchData == refSearchData,
            "searchData assertion @ mkTestCacheFIFO",
            $format(
                "searchData=%h should == refSearchData=%h",
                searchData, refSearchData
            )
        );
        // $display(
        //     "time=%0t: searchData=%h should == refSearchData=%h",
        //     $time, searchData, refSearchData
        // );
    endrule
endmodule

(* synthesize *)
module mkTestVectorSearch(Empty);
    Vector#(MAX_QP_RD_ATOM, Reg#(ItemType)) searchVec <- replicateM(mkRegU);
    Vector#(MAX_QP_RD_ATOM, Reg#(Bool)) tagVec <- replicateM(mkReg(False));

    Count#(Bit#(TLog#(MAX_QP_RD_ATOM))) elemCnt <- mkCount(0);

    PipeOut#(ItemType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ItemType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4SearchRef <- mkBufferN(valueOf(MAX_QP_RD_ATOM), qElemPipeOutVec[1]);
    let qElemPipeOut4DeqRef <- mkBufferN(valueOf(MAX_QP_RD_ATOM), qElemPipeOutVec[2]);
    Reg#(FifoTestState) searchTestStateReg <- mkReg(TEST_Q_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function Bool searchFunc(ItemType searchItem, Tuple2#(Bool, ItemType) fifoItem);
        return tpl_1(fifoItem) && searchItem == getTupleSecond(fifoItem);
    endfunction

    rule fillSearchQ if (searchTestStateReg == TEST_Q_FILL);
        if (isAllOnes(elemCnt)) begin
            elemCnt <= 0;
            searchTestStateReg <= TEST_Q_ACT;
        end
        else begin
            elemCnt.incr(1);
        end

        let curEnqData = qElemPipeOut4Q.first;
        qElemPipeOut4Q.deq;

        tagVec[elemCnt] <= True;
        searchVec[elemCnt] <= curEnqData;
        // $display(
        //     "time=%0t: curEnqData=%h when in fill mode",
        //     $time, curEnqData
        // );
    endrule

    rule compareSearch if (searchTestStateReg == TEST_Q_ACT);
        if (isAllOnes(elemCnt)) begin
            elemCnt <= 0;
            searchTestStateReg <= TEST_Q_POP;
        end
        else begin
            elemCnt.incr(1);
        end

        let refSearchData = qElemPipeOut4SearchRef.first;
        qElemPipeOut4SearchRef.deq;

        let zipVec = zip(readVReg(tagVec), readVReg(searchVec));
        let maybeFindData = findIndex(searchFunc(refSearchData), zipVec);
        // let maybeFindData = findElem(tuple2(True, refSearchData), zipVec);
        // let maybeFindData = find(searchFunc(refSearchData), zipVec);
        immAssert(
            isValid(maybeFindData),
            "maybeFindData assertion @ mkTestSearchFIFOF",
            $format(
                "maybeFindData=", fshow(maybeFindData),
                " should be valid"
            )
        );

        let index = unwrapMaybe(maybeFindData);
        let { curSearchTag, curSearchData } = zipVec[index];
        // let { curSearchTag, curSearchData } = unwrapMaybe(maybeFindData);
        immAssert(
            curSearchTag && curSearchData == refSearchData,
            "curSearchData assertion @ mkTestSearchFIFOF",
            $format(
                "curSearchData=%h should == refSearchData=%h",
                curSearchData, refSearchData,
                ", and curSearchTag=", fshow(curSearchTag),
                " should be true"
            )
        );
        // $display(
        //     "time=%0t: curSearchData=%h should == refSearchData=%h",
        //     $time, curSearchData, refSearchData,
        //     ", and curSearchTag=", fshow(curSearchTag),
        //     " should be true"
        // );
    endrule

    rule compareDeq if (searchTestStateReg == TEST_Q_POP);
        if (isAllOnes(elemCnt)) begin
            elemCnt <= 0;
            searchTestStateReg <= TEST_Q_FILL;
        end
        else begin
            elemCnt.incr(1);
        end

        countDown.decr;

        tagVec[elemCnt] <= False;
        let curDeqData = searchVec[elemCnt];

        let refDeqData = qElemPipeOut4DeqRef.first;
        qElemPipeOut4DeqRef.deq;

        immAssert(
            curDeqData == refDeqData,
            "curDeqData assertion @ mkTestSearchFIFOF",
            $format(
                "curDeqData=%h should == refDeqData=%h when in deq mode",
                curDeqData, refDeqData
            )
        );
        // $display(
        //     "time=%0t: curDeqData=%h should == refDeqData=%h when in deq mode",
        //     $time, curDeqData, refDeqData
        // );
    endrule
endmodule
