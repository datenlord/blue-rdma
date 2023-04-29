import Cntrs :: *;
import List :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils4Test :: *;

(* synthesize *)
module mkTestCntrlInVec(Empty);
    let qpType = IBV_QPT_XRC_RECV;
    let pmtu = IBV_MTU_1024;

    let setExpectedPsnAsNextPSN = False;
    Vector#(MAX_QP, Controller) cntrlVec <- replicateM(mkSimController(
        qpType, pmtu, setExpectedPsnAsNextPSN
    ));
    Array#(Controller) cntrlArray = vectorToArray(cntrlVec);
    List#(Controller) cntrlList = toList(cntrlVec);

    Count#(Bit#(TLog#(MAX_QP))) qpCnt <- mkCount(0);
    Reg#(Bool) stateReg <- mkReg(True);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule genCntrl if (stateReg);
        if (isAllOnes(qpCnt)) begin
            stateReg <= False;
            qpCnt <= 0;
        end
        else begin
            qpCnt.incr(1);
        end

        let cntrl = cntrlArray[qpCnt];
        // if (cntrl.isRTS) begin
        //     cntrl.setEPSN();
        // end
        cntrl.contextRQ.setCurRespPSN(cntrl.contextRQ.getEPSN);
        // $display(
        //     "time=%0t: cntrlVec[%0d].contextRQ.getEPSN=%h",
        //     $time, qpCnt, cntrl.contextRQ.getEPSN
        // );
    endrule

    rule cmpCntrl if (!stateReg);
        countDown.decr;

        if (isAllOnes(qpCnt)) begin
            stateReg <= True;
            qpCnt <= 0;
        end
        else begin
            qpCnt.incr(1);
        end

        let cntrl1 = cntrlVec[qpCnt];
        let cntrl2 = cntrlArray[qpCnt];

        immAssert(
            cntrl1.getQKEY == cntrl2.getQKEY,
            "qkey assertion @ mkTestCntrlInVec",
            $format(
                "cntrl1.getQKEY=%h == cntrl2.getQKEY=%h",
                cntrl1.getQKEY, cntrl2.getQKEY
            )
        );
        immAssert(
            cntrl1.contextRQ.getCurRespPSN == cntrl2.contextRQ.getEPSN,
            "curRespPsn assertion @ mkTestCntrlInVec",
            $format(
                "curRespPsn=%h == cntrl2.contextRQ.getEPSN=%h",
                cntrl1.contextRQ.getCurRespPSN, cntrl2.contextRQ.getEPSN
            )
        );
        // $display(
        //     "time=%0t: cntrl1.getQKEY=%h == cntrl2.getQKEY=%h",
        //     $time, cntrl1.getQKEY, cntrl2.getQKEY
        // );
    endrule
endmodule
