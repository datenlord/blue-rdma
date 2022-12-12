import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import ScanFIFOF :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

typedef Bit#(64) ScanType;

typedef enum {
    Q_FILL,
    Q_SCAN,
    Q_POP
} ScanTestState deriving(Bits, Eq);

(* synthesize *)
module mkTestScanFIFOF(Empty);
    ScanFIFOF#(MAX_PENDING_REQ_NUM, ScanType) scanQ <- mkScanFIFOF;
    PipeOut#(ScanType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ScanType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4DeqRef  <- mkBufferN(valueOf(MAX_PENDING_REQ_NUM), qElemPipeOutVec[1]);
    let qElemPipeOut4ScanRef <- mkBufferN(valueOf(MAX_PENDING_REQ_NUM), qElemPipeOutVec[2]);
    Reg#(ScanTestState) scanTestStateReg <- mkReg(Q_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule fillScanQ if (scanTestStateReg == Q_FILL);
        if (scanQ.fifoF.notFull) begin
            let curEnqData = qElemPipeOut4Q.first;
            qElemPipeOut4Q.deq;

            scanQ.fifoF.enq(curEnqData);
        end
        else begin
            scanTestStateReg <= Q_SCAN;
            scanQ.scanIfc.scanStart;
        end
    endrule

    rule compareScan if (scanTestStateReg == Q_SCAN);
        if (scanQ.scanIfc.scanDone) begin
            scanTestStateReg <= Q_POP;
        end
        else begin
            let curScanData = scanQ.scanIfc.current;
            scanQ.scanIfc.scanNext;

            let refScanData = qElemPipeOut4ScanRef.first;
            qElemPipeOut4ScanRef.deq;

            dynAssert(
                curScanData == refScanData,
                "curScanData assertion @ mkTestScanFIFOF",
                $format(
                    "curScanData=%h should == refScanData=%h when in scan mode",
                    curScanData, refScanData
                )
            );
            // $display(
            //     "time=%0d: curScanData=%h should == refScanData=%h when in scan mode",
            //     $time, curScanData, refScanData
            // );
        end
    endrule

    rule compareDeq if (scanTestStateReg == Q_POP);
        if (scanQ.fifoF.notEmpty) begin
            countDown.dec;

            let curDeqData = scanQ.fifoF.first;
            scanQ.fifoF.deq;

            let refDeqData = qElemPipeOut4DeqRef.first;
            qElemPipeOut4DeqRef.deq;

            dynAssert(
                curDeqData == refDeqData,
                "curDeqData assertion @ mkTestScanFIFOF",
                $format(
                    "curDeqData=%h should == refDeqData=%h when in deq mode",
                    curDeqData, refDeqData
                )
            );
            // $display(
            //     "time=%0d: curDeqData=%h should == refDeqData=%h when in deq mode",
            //     $time, curDeqData, refDeqData
            // );
        end
        else begin
            scanTestStateReg <= Q_FILL;
        end
    endrule
endmodule
