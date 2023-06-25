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

    Vector#(MAX_QP, Controller) cntrlVec <- replicateM(
        mkSimCntrl(qpType, pmtu)
    );
    // let setExpectedPsnAsNextPSN = False;
    // Vector#(MAX_QP, Controller) cntrlVec <- replicateM(mkSimController(
    //     qpType, pmtu, setExpectedPsnAsNextPSN
    // ));
    Array#(Controller) cntrlArray = vectorToArray(cntrlVec);
    List#(Controller) cntrlList = toList(cntrlVec);

    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) qpCnt <- mkCount(0);
    Reg#(Bool) stateReg <- mkReg(True);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule setCntrl if (stateReg);
        let cntrl = cntrlArray[qpCnt];

        if (qpCnt == fromInteger(valueOf(MAX_QP))) begin
            stateReg <= False;
            qpCnt <= 0;
        end
        else if (cntrl.cntrlStatus.isStableRTS) begin
            cntrl.contextRQ.setCurRespPSN(cntrl.contextRQ.getEPSN);
            qpCnt.incr(1);

            // $display(
            //     "time=%0t: cntrlVec[%0d].contextRQ.getEPSN=%h",
            //     $time, qpCnt, cntrl.contextRQ.getEPSN
            // );
        end
    endrule

    rule cmpCntrl if (!stateReg);
        countDown.decr;

        if (qpCnt == fromInteger(valueOf(MAX_QP))) begin
            stateReg <= True;
            qpCnt <= 0;
        end
        else begin
            qpCnt.incr(1);

            let cntrl1 = cntrlVec[qpCnt];
            let cntrl2 = cntrlArray[qpCnt];

            immAssert(
                cntrl1.cntrlStatus.getQKEY == cntrl2.cntrlStatus.getQKEY,
                "qkey assertion @ mkTestCntrlInVec",
                $format(
                    "cntrl1.cntrlStatus.getQKEY=%h == cntrl2.cntrlStatus.getQKEY=%h",
                    cntrl1.cntrlStatus.getQKEY, cntrl2.cntrlStatus.getQKEY
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
            //     "time=%0t: cntrl1.cntrlStatus.getQKEY=%h == cntrl2.cntrlStatus.getQKEY=%h",
            //     $time, cntrl1.cntrlStatus.getQKEY, cntrl2.cntrlStatus.getQKEY
            // );
        end
    endrule
endmodule
